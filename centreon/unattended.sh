#!/bin/sh

### Define all supported constants
OPTIONS="hst:v:r:l:p:"
declare -A SUPPORTED_LOG_LEVEL=([DEBUG]=0 [INFO]=1 [WARN]=2 [ERROR]=3)
declare -A SUPPORTED_TOPOLOGY=([central]=1 [poller]=1)
declare -A SUPPORTED_VERSION=([21.10]=1 [22.04]=1 [22.10]=1 [23.04]=1 [23.10]=1 [24.04]=1)
declare -A SUPPORTED_REPOSITORY=([testing]=1 [unstable]=1 [stable]=1)
default_timeout_in_sec=5
script_short_name="$(basename $0)"
default_ip=$(hostname -I | awk '{print $1}')
###

#Define default values

passwords_file=/etc/centreon/generated.tobesecured         #File where the generated passwords will be temporaly saved
tmp_passwords_file=$(mktemp /tmp/generated.XXXXXXXXXXXXXX) #Random tmp file as the /etc/centreon does not exist yet

topology=${ENV_CENTREON_TOPOLOGY:-"central"}    #Default topology to be installed
version=${ENV_CENTREON_VERSION:-"24.04"}        #Default version to be installed
repo=${ENV_CENTREON_REPO:-"stable"}             #Default repository to used
operation=${ENV_CENTREON_OPERATION:-"install"}  #Default operation to be executed
runtime_log_level=${ENV_LOG_LEVEL:-"INFO"}      #Default log level to be used
selinux_mode=${ENV_SELINUX_MODE:-"permissive"}  #Default SELinux mode to be used
wizard_autoplay=${ENV_WIZARD_AUTOPLAY:-"false"} #Default the install wizard is not run auto
central_ip=${ENV_CENTRAL_IP:-$default_ip}       #Default central ip is the first of hostname -I

function genpasswd() {
	local _pwd

	PWD_LOWER=$(cat /dev/urandom | tr -dc 'a-z' | head -c4)
	PWD_UPPER=$(cat /dev/urandom | tr -dc 'A-Z' | head -c4)
	PWD_DIGIT=$(cat /dev/urandom | tr -dc '0-9' | head -c4)
	PWD_SPECIAL=$(cat /dev/urandom | tr -dc '\!\@\$\*\?' | head -c4)

	_pwd="$PWD_LOWER$PWD_UPPER$PWD_DIGIT$PWD_SPECIAL"
	_pwd=$(echo $_pwd |fold -w 1 |shuf |tr -d '\n')

	echo "Random password generated for user [$1] is [$_pwd]" >>$tmp_passwords_file

	if [ $? -ne 0 ]; then
		echo "ERROR: Cannot save the random password to [$tmp_passwords_file]"
		exit 1
	fi

	#return the generated password
	echo $_pwd
}

CENTREON_MAJOR_VERSION=$version
CENTREON_RELEASE_VERSION="$CENTREON_MAJOR_VERSION-1"

# Static variables
PHP_BIN="/usr/bin/php"
PHP_ETC="/etc/php.d/"

# Variables dynamically set
detected_os_release=
detected_os_version=
detected_mariadb_version=
centreon_admin_password=

# Variables will be defined later according to the target system OS
BASE_PACKAGES=
CENTREON_SELINUX_PACKAGES=
RELEASE_REPO_FILE=
OS_SPEC_SERVICES=
PKG_MGR=
has_systemd=
CENTREON_REPO=
CENTREON_DOC_URL=

#########################################################
############### ALL INTERNAL FUNCTIONS ##################

#========= begin of function usage()
# display help usage
#
function usage() {

	echo
	echo "Usage:"
	echo
	echo " $script_short_name [install|update (default: install)] [-t <central|poller> (default: central)] [-v <24.04> (default: 24.04)] [-r <stable|testing|unstable> (default: stable)] [-l <DEBUG|INFO|WARN|ERROR>] [-s (for silent install)] [-p <centreon admin password>] [-h (show this help output)]"
	echo
	echo Example:
	echo
	echo " $script_short_name == install the $version of $topology from the repository $repo"
	echo
	echo " $script_short_name install -r unstable,testing == install the central to the $version from the unstable & testing repository"
	echo
	exit 1
}
#======== end of function usage()

#========= begin of function log()
# print out the message according to the level
# with timestamp
#
# usage:
# log "$LOG_LEVEL" "$message" ($LOG_LEVEL = DEBUG|INFO|WARN|ERROR)
#
# example:
# log "DEBUG" "This is a DEBUG_LOG_LEVEL message"
# log "INFO" "This is a INFO_LOG_LEVEL message"
#
function log() {

	TIMESTAMP=$(date --rfc-3339=seconds)

	if [[ -z "${1}" || -z "${2}" ]]; then
		echo "${TIMESTAMP} - ERROR: Missing argument"
		echo "${TIMESTAMP} - ERROR: Usage log \"INFO\" \"Message log\" "
		exit 1
	fi

	# get the message log level
	log_message_level="${1}"

	# shift once to get the log message (string or array)
	shift

	# get the log message (full log message)
	log_message="${@}"

	# check if the log_message_level is greater than the runtime_log_level
	[[ ${SUPPORTED_LOG_LEVEL[$log_message_level]} ]] || return 1

	((${SUPPORTED_LOG_LEVEL[$log_message_level]} < ${SUPPORTED_LOG_LEVEL[$runtime_log_level]})) && return 2

	echo -e "${TIMESTAMP} - $log_message_level - $log_message"

}
#======== end of function log()

#========= begin of function parse_subcommand_options()
# parse the provided arguments and check values
# the script will display usage (and aborted) for any
# unsupported argument/option (which are defined in constants)
#
function parse_subcommand_options() {
	local requested_topology=""
	local requested_version=""
	local requested_repo=""
	local OPTIND
	OPTIND=2
	while getopts $OPTIONS opt; do
		case ${opt} in
		t)
			requested_topology=$OPTARG
			log "INFO" "Requested topology: '$requested_topology'"

			[[ ! ${SUPPORTED_TOPOLOGY[$requested_topology]} ]] &&
				log "ERROR" "Unsupported topology: $requested_topology" &&
				usage
			;;

		v)
			requested_version=$OPTARG
			log "INFO" "Requested version: '$requested_version'"

			[[ ! ${SUPPORTED_VERSION[$requested_version]} ]] &&
				log "ERROR" "Unsupported version: $requested_version" &&
				usage
			;;

		r)
			requested_repo=$OPTARG
			log "INFO" "Requested repository: '$requested_repo'"
			get_os_information
			set_centreon_repos $requested_repo
			;;

		l)
			log_level=$OPTARG
			if [ ! ${SUPPORTED_LOG_LEVEL[$log_level]} ]; then
				log "ERROR" "Unsupported and ignored log level: $log_level"
			else
				runtime_log_level=$log_level
			fi
			log "INFO" "Runtime log level set: $runtime_log_level"
			;;

        s)
		    wizard_autoplay="true"
			log "INFO" "The installation wizard will be executed by the script"
			;;
		p)
			centreon_admin_password=$OPTARG
			;;
		\?)
			log "ERROR" "Invalid option: -"$OPTARG""
			usage
			exit 1
			;;

		h)
			usage
			exit 0
			;;

		:)
			log "ERROR" "Option -"$OPTARG" requires an argument."
			usage
			exit 1
			;;
		esac
	done
	shift $((OPTIND - 1))

	## check the configuration parameters
	if [ -z "${requested_topology}" ]; then
		log "WARN" "No topology provided: default value [$topology] will be used"
	else
		topology=$requested_topology
	fi

	if [ -z "${requested_version}" ]; then
		log "WARN" "No version provided: default value [$version] will be used"
	else
		version=$requested_version
	fi

	if [ -z "${requested_repo}" ]; then
		log "WARN" "No repository provided: default value [$repo] will be used"
	else
		repo=$requested_repo
	fi
}
#======== end of function parse_subcommand_options()

#========= begin of function error_and_exit()
# display the ERROR log message then exit the script
function error_and_exit() {
	log "ERROR" "$1"
	exit 1
}
#========= end of function error_and_exit()

#========= begin of function pause()
# add pause prompt message ($1) for ($2) seconds
#
function pause() {
	local timeout=$default_timeout_in_sec
	if [ -n $2 ]; then
		timeout=$2
	fi
	read -t $timeout -s -n 1 -p "${1}"
	echo ""
}
#========= end of function pause()

#========= begin of function get_os_information()
# get the OS release
# if the detected release is not supported the script will be ended
#
function get_os_information() {

	# Get OS name
	OS_NAME=$(grep "^NAME=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
	# Get OS version
	OS_VERSIONID=$(grep "^VERSION_ID=" /etc/os-release | cut -d'=' -f2 | tr -d '"')

	if [[ "$(echo "${OS_NAME}" | wc -l)" -ne 1 || "$(echo "${OS_VERSIONID}" | wc -l)" -ne 1 ]]; then
		error_and_exit "Unable to determine your running OS or version."
	fi

	case "${OS_NAME}" in
		AlmaLinux*)
			detected_os_release="almalinux-release-${OS_VERSIONID}"
			;;
		CentOS*)
			detected_os_release="centos-release-${OS_VERSIONID}"
			;;
		Debian*)
			case "${OS_VERSIONID}" in
				11*|12*)
					detected_os_release="debian-release-${OS_VERSIONID}"
					;;
				*)
					log "ERROR" "Unsupported Debian distribution ${OS_VERSIONID} detected"
					;;
			esac
			;;
		Oracle*)
			detected_os_release="oraclelinux-release-${OS_VERSIONID}"
			;;
		"Red Hat"*)
			detected_os_release="redhat-release-${OS_VERSIONID}"
			;;
		Rocky*)
			detected_os_release="rocky-release-${OS_VERSIONID}"
			;;
		*)
			log "ERROR" "Unsupported distribution ${OS_NAME} detected"
			error_and_exit "This '$script_short_name' script only supports Red-Hat compatible distributions (v8 and v9) and Debian 11/12. Please check https://docs.centreon.com/docs/installation/introduction for alternative installation methods."
			;;
	esac

	detected_os_version=${OS_VERSIONID}

	log "INFO" "Your running OS is $detected_os_release (version: ${detected_os_version})"

}
#========= end of function get_os_information()

#========= begin of function set_centreon_repos()
# split the repos from the args (separated by , )
# then concat the string for $CENTREON_REPO
#
function set_centreon_repos() {
	if ! [ -z $1 ]; then
		repo=$1
	fi

	IFS=', ' read -r -a array_repos <<<"$repo"

	CENTREON_REPO=""
	for _repo in "${array_repos[@]}"; do

		[[ ! ${SUPPORTED_REPOSITORY[$_repo]} ]] &&
			log "ERROR" "Unsupported repository: $_repo" &&
			usage

		if [[ "${detected_os_release}" =~ debian-release-.* ]]; then
			CENTREON_REPO+="$version-$_repo"
		else
			CENTREON_REPO+="centreon-$version-$_repo*"
		fi

		if ! [ "$_repo" == "${array_repos[@]:(-1)}" ]; then
			CENTREON_REPO+=","
		fi
	done

	log "INFO" "Following Centreon repo will be used: [$CENTREON_REPO]"

}
#========= end of function set_centreon_repos()

#========= begin of function set_mariadb_repos()
#
function set_mariadb_repos() {
	log "INFO" "Install MariaDB repository"
	case $version in
	"24.04")
		detected_mariadb_version="10.11"
	;;
	*)
		detected_mariadb_version="10.5"
	;;
	esac
	case "$detected_os_release" in
	debian-release*)
		curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --os-type=debian --os-version=$detected_os_version --mariadb-server-version=$detected_mariadb_version
		if [ $? -ne 0 ]; then
			error_and_exit "Could not install the repository"
		else
			log "INFO" "Successfully installed MariaDB repository"
		fi
		rm -f /etc/apt/sources.list.d/mariadb.list.old_*  > /dev/null 2>&1
		;;
	*)
		curl -LsS https://r.mariadb.com/downloads/mariadb_repo_setup | bash -s -- --mariadb-server-version=$detected_mariadb_version
		if [ $? -ne 0 ]; then
			error_and_exit "Could not install the repository"
		else
			log "INFO" "Successfully installed MariaDB repository"
		fi
		rm -f /etc/yum.repos.d/mariadb.repo.old_* > /dev/null 2>&1
		;;
	esac
}
#========= end of function set_mariadb_repos()

#========= begin of function set_required_prerequisite()
# check if the target OS is compatible with Red Hat and the version is 8 or 9
# then set the required environment variables accordingly
#
function set_required_prerequisite() {
	log "INFO" "Check if the system OS is supported and set the environment variables"

	get_os_information

    case "$detected_os_release" in
	redhat-release* | centos-release-* | centos-linux-release* | centos-stream-release* | almalinux-release* | rocky-release*)
		case "$detected_os_version" in
		8*)
			log "INFO" "Setting specific part for v8 ($detected_os_version)"

			RELEASE_REPO_FILE="https://packages.centreon.com/artifactory/rpm-standard/$version/el8/centreon-$version.repo"
			REMI_RELEASE_RPM_URL="https://rpms.remirepo.net/enterprise/remi-release-8.rpm"
			OS_SPEC_SERVICES="php-fpm httpd"
			PKG_MGR="dnf"

			case "$detected_os_release" in
			redhat-release*)
				BASE_PACKAGES=(dnf-plugins-core epel-release)
				subscription-manager repos --enable codeready-builder-for-rhel-8-x86_64-rpms
				$PKG_MGR config-manager --set-enabled codeready-builder-for-rhel-8-rhui-rpms
				;;

			centos-release-8.[3-9]* | centos-linux-release* | centos-stream-release* | almalinux-release* | rocky-release*)
				BASE_PACKAGES=(dnf-plugins-core epel-release)
				$PKG_MGR config-manager --set-enabled powertools
				;;

			centos-release-8.[1-2]*)
				BASE_PACKAGES=(dnf-plugins-core epel-release)
				$PKG_MGR config-manager --set-enabled PowerTools
				;;

			oraclelinux-release* | enterprise-release*)
				BASE_PACKAGES=(dnf-plugins-core)
				$PKG_MGR config-manager --set-enabled ol8_codeready_builder
				dnf install -y http://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
			;;
			esac

			if [ "$topology" == "central" ]; then
				install_remi_repo

				if [[ "$version" == "21.10" || "$version" == "22.04" ]]; then
					log "INFO" "Installing PHP 8.0 and enable it"
					$PKG_MGR module reset php -y -q
					$PKG_MGR module install php:remi-8.0 -y -q
				else
					log "INFO" "Installing PHP 8.1 and enable it"
					$PKG_MGR module install php:remi-8.1 -y -q
					$PKG_MGR module enable php:remi-8.1 -y -q
				fi
			fi
			;;

		9*)
			if ! [[ "$version" == "23.04" || "$version" == "23.10" || "$version" == "24.04" ]]; then
				error_and_exit "Only Centreon version >=23.04 is compatible with EL9, you chose $version"
			fi

			log "INFO" "Setting specific part for v9 ($detected_os_version)"

			RELEASE_REPO_FILE="https://packages.centreon.com/artifactory/rpm-standard/$version/el9/centreon-$version.repo"
			OS_SPEC_SERVICES="php-fpm httpd"
			PKG_MGR="dnf"

			case "$detected_os_release" in
			redhat-release*)
				BASE_PACKAGES=(dnf-plugins-core epel-release)
				subscription-manager repos --enable codeready-builder-for-rhel-9-x86_64-rpms
				$PKG_MGR config-manager --set-enabled codeready-builder-for-rhel-9-rhui-rpms
				;;

			centos-release* | centos-linux-release* | centos-stream-release* | almalinux-release* | rocky-release*)
				BASE_PACKAGES=(dnf-plugins-core epel-release)
				$PKG_MGR config-manager --set-enabled crb
				;;

			oraclelinux-release* | enterprise-release*)
				BASE_PACKAGES=(dnf-plugins-core)
				$PKG_MGR config-manager --set-enabled ol9_codeready_builder
				dnf install -y http://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
			;;
			esac

			if [ "$topology" == "central" ]; then
				log "INFO" "Installing PHP 8.1 and enable it"
				$PKG_MGR module install php:8.1 -y -q
				$PKG_MGR module enable php:8.1 -y -q
			fi
			;;

		*)
			error_and_exit "This '$script_short_name' script only supports Red-Hat compatible distribution (v8 and v9) and Debian 11/12. Please check https://docs.centreon.com/docs/installation/introduction for alternative installation methods."
			;;
		esac

		log "INFO" "Installing packages ${BASE_PACKAGES[@]}"
		$PKG_MGR -q install -y ${BASE_PACKAGES[@]}

		log "INFO" "Updating package gnutls"
		$PKG_MGR -q update -y gnutls

		set_centreon_repos
		if [ "$topology" == "central" ]; then
			set_mariadb_repos
			log "INFO" "Installing glibc langpack for Centreon UI translation"
			$PKG_MGR-q install -y glibc-langpack-fr glibc-langpack-es glibc-langpack-pt glibc-langpack-de > /dev/null 2>&1
		fi
		;;
	debian-release*)
		case "$detected_os_version" in
		11)
			if ! [[ "$version" == "22.04" || "$version" == "22.10" || "$version" == "23.04" || "$version" == "23.10" || "$version" == "24.04" ]]; then
				error_and_exit "For Debian, only Centreon versions >= 22.04 are compatible. You chose $version"
			fi
			;;
		12)
			if ! [[ "$version" == "24.04" ]]; then
				error_and_exit "For Debian, only Centreon versions >= 24.04 are compatible. You chose $version"
			fi
			;;
		*)
			error_and_exit "This '$script_short_name' script only supports Red-Hat compatible distribution (v8 and v9) and Debian 11/12. Please check https://docs.centreon.com/docs/installation/introduction for alternative installation methods."
			;;
		esac
		OS_SPEC_SERVICES="php8.1-fpm apache2"
		log "INFO" "Setting specific part for Debian"
		PKG_MGR="apt -qq"
		${PKG_MGR} update && ${PKG_MGR} install -y lsb-release ca-certificates apt-transport-https software-properties-common wget gnupg2 curl

		# Get CPU architecture type
		VENDORID=$(lscpu | grep -e '^Vendor ID:' | cut -d ':' -f2 | tr -d '[:space:]')
		ARCH=""
		if [[ "$VENDORID" == "ARM" ]]; then
			ARCH="[ arch=all,arm64 ]"
			if ! [[ "$version" == "23.10" || "$version" == "24.04" || "$topology" == "poller" ]]; then
				error_and_exit "For Debian on Raspberry, only Centreon versions (poller mode) >=23.10 are compatible. You chose $version to install $topology server"
			fi
		fi

		# Add Centreon repositories
		set_centreon_repos
		IFS=', ' read -r -a array_apt <<<"$CENTREON_REPO"
		for _repo in "${array_apt[@]}"; do
			echo "deb https://packages.centreon.com/apt-standard-$_repo/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/centreon-$_repo.list

			SIMPLEREPO=$(echo $_repo | cut -d '-' -f2)
			echo "deb $ARCH https://packages.centreon.com/apt-plugins-$SIMPLEREPO/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/centreon-plugins-$SIMPLEREPO.list
		done
		wget -O- https://apt-key.centreon.com | gpg --dearmor | tee /etc/apt/trusted.gpg.d/centreon.gpg > /dev/null 2>&1

		if [ "$topology" == "central" ]; then
			# Add PHP repo
			echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list
			wget -O- https://packages.sury.org/php/apt.gpg | gpg --dearmor | tee /etc/apt/trusted.gpg.d/php.gpg  > /dev/null 2>&1
			set_mariadb_repos
		else
			${PKG_MGR} update
		fi
	esac
}
#========= end of function set_required_prerequisite()

#========= begin of function is_systemd_present()
#
function is_systemd_present() {
	# systemd check.
	running_process=$(ps --no-headers -o comm 1)
	if [ "$running_process" == "systemd" ]; then
		has_systemd=1
		log "INFO" "Systemd is running"
	else
		has_systemd=0
		log "WARN" "Systemd is not running"
	fi
}
#========= end of function is_systemd_present()

#========= begin of function set_selinux_config()
# change SELinux config: $1 (permissive | enforcing | disabled)
#
function set_selinux_config() {

	log "INFO" "Change SELinux config to mode [$1]"

	if [ -e /etc/selinux/config ]; then
		log "WARN" "Modifying /etc/selinux/config. You must reboot your machine."

		sed -i "s/^SELINUX=.*\$/SELINUX=$1/" /etc/selinux/config

		if [ $? -ne 0 ]; then
			error_and_exit "Could not change SELinux mode. You might need to run this script as root."
		fi
	else
		log "WARN" "Cannot read /etc/selinux/config. Do nothing"
	fi

}
#========= end of function set_selinux_config()

#========= begin of function set_runtime_selinux_mode ()
# set runtime SELinux mode: $1 (permissive | enforcing)
#
function set_runtime_selinux_mode() {

	log "INFO" "Set runtime SELinux mode to [$1]"

	_current_mode=$(getenforce | tr '[:upper:]' '[:lower:]')

	log "DEBUG" "Current SELinux mode is [$_current_mode]"

	shopt -s nocasematch

	if [ "$_current_mode" == "$1" ]; then
		log "DEBUG" "Current SELinux mode is already set as requested. Nothing to do"
		return
	fi

	_request_mode=0 #Default mode is permissive
	case $1 in
	permissive)
		log "DEBUG" "Change runtime mode to [permissive]"
		_request_mode=0
		;;

	enforcing)
		log "DEBUG" "Change runtime mode to [enforcing]"
		_request_mode=1
		;;
	esac

	setenforce $_request_mode

	if [ $? -eq 2 ]; then
		error_and_exit "Could not change SELinux mode. You might need to run this script as root."
	elif [ $? -eq 1 ]; then
		log "WARN" "Current SELinux mode is disabled. Nothing to do"
	fi

}

#========= end of function set_runtime_selinux_mode()

#========= begin of function secure_mariadb_setup()
# apply some secure requests
#
function secure_mariadb_setup() {

	log "INFO" "Secure MariaDB setup..."
	log "WARN" "We are applying some requests that will enhance your MariaDB setup security"
	log "WARN" "Please consult the official documentation https://mariadb.com/kb/en/mysql_secure_installation/ for more details"
	log "WARN" "You can use mysqladmin in order to set a new password for user root"

	log "INFO" "Restarting MariaDB service first"
	systemctl restart mariadb

	log "INFO" "Executing SQL requests"
	mysql -u root <<-EOF
		UPDATE mysql.global_priv SET priv=json_set(priv, '$.plugin', 'mysql_native_password', '$.authentication_string', PASSWORD('$mariadb_root_password')) WHERE User='root';
		DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
		DELETE FROM mysql.global_priv WHERE User='';
		DROP DATABASE IF EXISTS test;
		DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
		FLUSH PRIVILEGES;
	EOF

	if [ $? -ne 0 ]; then
		error_and_exit "Could not apply the requests"
	else
		log "INFO" "Successfully applied the SQL requests for enhancing your MariaDB"
	fi

}
#========= end of function secure_mariadb_setup()

#========= begin of function install_centreon_repo()
# install the centos-release-scl under CentOS7
# then install Centreon official repositories
#
function install_centreon_repo() {

	log "INFO" "Centreon official repositories installation..."

	$PKG_MGR config-manager --add-repo $RELEASE_REPO_FILE
	if [ $? -ne 0 ]; then
		error_and_exit "Could not install Centreon repository"
	fi
}
#========= end of function install_centreon_repo()

#========= begin of function install_remi_repo()
# install Remi repositories
#
function install_remi_repo() {

	log "INFO" "Remi repositories installation..."
	$PKG_MGR -q clean all

	rpm -q remi-release >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		$PKG_MGR -q install -y $REMI_RELEASE_RPM_URL
		if [ $? -ne 0 ]; then
			error_and_exit "Could not install Remi repository"
		fi
	else
		log "INFO" "Remi repository seems to be already installed"
	fi
}
#========= end of function install_remi_repo()

#========= begin of function update_firewall_config()
# add firewall configuration for newly added services
#
function update_firewall_config() {

	log "INFO" "Update firewall configuration..."
	command -v firewall-cmd >/dev/null 2>&1

	if [ $? -eq 0 ]; then
		firewall-cmd --state >/dev/null 2>&1
		if [ $? -eq 0 ]; then
			for svc in http snmp snmptrap; do
				firewall-cmd --zone=public --add-service=$svc --permanent >/dev/null 2>&1
				if [ $? -ne 0 ]; then
					error_and_exit "Could not configure firewall. You might need to run this script as root."
				fi
			done
			for port in "5556/tcp" "5669/tcp"; do
				firewall-cmd --zone=public --add-port=$port --permanent >/dev/null 2>&1
				if [ $? -ne 0 ]; then
					error_and_exit "Could not configure firewall. You might need to run this script as root."
				fi
			done
			log "INFO" "Reloading firewall rules"
			firewall-cmd --reload
		else
			log "WARN" "Firewall was not active"
		fi
	else
		log "WARN" "Firewall was not detected"
	fi
}
#========= end of function update_firewall_config()

#========= begin of function enable_new_services()
# enable newly added services to make them active after system reboot
#
function enable_new_services() {

	log "INFO" "Enable and restart services ..."
	if [ $has_systemd -eq 1 ]; then
		case $topology in

		central)
			log "DEBUG" "On central..."
			systemctl enable mariadb $OS_SPEC_SERVICES snmpd snmptrapd gorgoned centreontrapd cbd centengine centreon
			systemctl restart mariadb $OS_SPEC_SERVICES snmpd snmptrapd
			systemctl start centreontrapd
			;;

		poller)
			log "DEBUG" "On poller..."
			systemctl enable centreon centengine centreontrapd snmpd snmptrapd gorgoned
			systemctl start centreontrapd snmptrapd
			;;
		esac
	else
		log "WARN" "Systemd not detected, skipping"
	fi
}
#========= end of function enable_new_services()

#========= begin of function setup_before_installation()
# execute some tasks before installing Centreon
# - disable SELinux
# - install Centreon official repositories
function setup_before_installation() {

	set_runtime_selinux_mode "disabled"

	install_centreon_repo
}
#========= end of function setup_before_installation()

#========= begin of function install_wizard_post()
# execute a post request of the install wizard
# - session cookie
# - php command
# - request body
function install_wizard_post() {
	log "INFO" " wizard install step ${2} response ->  $(curl -s -o /dev/null -w "%{http_code}" "http://${central_ip}/centreon/install/steps/process/${2}" \
		-H 'Content-Type: application/x-www-form-urlencoded; charset=UTF-8' \
		-H "Cookie: ${1}" --data "${3}")"
}
#========= end of function install_wizard_post()

#========= begin of function play_install_wizard()
function play_install_wizard() {
	log "INFO" "Playing install wizard"

	sessionID=$(curl -s -v "http://${central_ip}/centreon/install/install.php" 2>&1 | grep Set-Cookie | awk '{print $3}')
	curl -s "http://${central_ip}/centreon/install/steps/step.php?action=stepContent" -H "Cookie: ${sessionID}" >/dev/null
	install_wizard_post ${sessionID} "process_step3.php" 'centreon_engine_stats_binary=%2Fusr%2Fsbin%2Fcentenginestats&monitoring_var_lib=%2Fvar%2Flib%2Fcentreon-engine&centreon_engine_connectors=%2Fusr%2Flib64%2Fcentreon-connector&centreon_engine_lib=%2Fusr%2Flib64%2Fcentreon-engine&centreonplugins=%2Fusr%2Flib%2Fcentreon%2Fplugins%2F'
	install_wizard_post ${sessionID} "process_step4.php" 'centreonbroker_etc=%2Fetc%2Fcentreon-broker&centreonbroker_cbmod=%2Fusr%2Flib64%2Fnagios%2Fcbmod.so&centreonbroker_log=%2Fvar%2Flog%2Fcentreon-broker&centreonbroker_varlib=%2Fvar%2Flib%2Fcentreon-broker&centreonbroker_lib=%2Fusr%2Fshare%2Fcentreon%2Flib%2Fcentreon-broker'
	install_wizard_post ${sessionID} "process_step5.php" "admin_password=${centreon_admin_password}&confirm_password=${centreon_admin_password}&firstname=${centreon_admin_firstname}&lastname=${centreon_admin_lastname}&email=${centreon_admin_email}"
	install_wizard_post ${sessionID} "process_step6.php" "address=&port=3306&root_user=root&root_password=${mariadb_root_password}&db_configuration=centreon&db_storage=centreon_storage&db_user=centreon&db_password=${mariadb_centreon_password}&db_password_confirm=${mariadb_centreon_password}"
	install_wizard_post ${sessionID} "configFileSetup.php"
	install_wizard_post ${sessionID} "installConfigurationDb.php"
	install_wizard_post ${sessionID} "installStorageDb.php"
	install_wizard_post ${sessionID} "createDbUser.php"
	install_wizard_post ${sessionID} "insertBaseConf.php"
	install_wizard_post ${sessionID} "partitionTables.php"
	install_wizard_post ${sessionID} "generationCache.php"
	install_wizard_post ${sessionID} "process_step8.php" 'modules%5B%5D=centreon-license-manager&modules%5B%5D=centreon-pp-manager&modules%5B%5D=centreon-autodiscovery-server&widgets%5B%5D=engine-status&widgets%5B%5D=global-health&widgets%5B%5D=graph-monitoring&widgets%5B%5D=grid-map&widgets%5B%5D=host-monitoring&widgets%5B%5D=hostgroup-monitoring&widgets%5B%5D=httploader&widgets%5B%5D=live-top10-cpu-usage&widgets%5B%5D=live-top10-memory-usage&widgets%5B%5D=service-monitoring&widgets%5B%5D=servicegroup-monitoring&widgets%5B%5D=tactical-overview&widgets%5B%5D=single-metric'
	install_wizard_post ${sessionID} "process_step9.php" 'send_statistics=1'
}
#========= end of function play_install_wizard()

#========= begin of function test_api_connection()
function test_api_connection () {
	log "INFO" "Test admin password to access Centreon's API"

	# Define temporary files
	api_output="/tmp/unattended.sh_api_output"
	api_return_code="/tmp/unattended.sh_api_return_code"
	api_error_message="/tmp/unattended.sh_api_error_message"
	api_error_keys="/tmp/unattended.sh_api_error_keys"

	#
	# Log in to Centreon API to get token
	#
	curl "${central_ip}/centreon/api/latest/login" \
	--silent \
	--insecure \
	--request POST \
	--header 'Content-Type: application/json' \
	--data "{\"security\": {\"credentials\": {\"login\": \"admin\",\"password\": \"${centreon_admin_password}\"}}}" \
	--output ${api_output} \
	--write-out %{http_code} \
	> ${api_return_code} 2> ${api_error_message}

	# Analyse result
	errorLevel=$?
	httpResponse=$(cat ${api_return_code})
	message=$(cat ${api_output})

	if [[ $errorLevel -gt 0 ]] || [[ "$httpResponse" != "200" ]]; then
		error_and_exit "API connection error (errorLevel $errorLevel, http response code $httpResponse, message: $message)"
	else
		token=$(echo $message | sed 's/.*{"token":"\(.*\)"}}/\1/g')
		if [ -z "${token}" ]; then
			error_and_exit "Unable to extract token from message: $message"
		fi
		log "DEBUG" "APIv2 token: ${token}"
	fi
}
#========= end of function test_api_connection()

#========= begin of function play_update_api()
function play_update_api () {
	log "INFO" "Install jq binary"
	$PKG_MGR -q install -y jq > /dev/null 2>&1

	log "INFO" "Update Centreon using API"

	# Define temporary files
	api_output="/tmp/unattended.sh_api_output"
	api_return_code="/tmp/unattended.sh_api_return_code"
	api_error_message="/tmp/unattended.sh_api_error_message"
	api_error_keys="/tmp/unattended.sh_api_error_keys"

	#
	# Log in to Centreon API to get token
	#
	curl "${central_ip}/centreon/api/latest/login" \
	--silent \
	--insecure \
	--request POST \
	--header 'Content-Type: application/json' \
	--data "{\"security\": {\"credentials\": {\"login\": \"admin\",\"password\": \"${centreon_admin_password}\"}}}" \
	--output ${api_output} \
	--write-out %{http_code} \
	> ${api_return_code} 2> ${api_error_message}

	# Analyse result
	errorLevel=$?
	httpResponse=$(cat ${api_return_code})
	message=$(cat ${api_output})
	if [[ -f ${api_output} && -s "${api_output}" ]];then
		jq --raw-output 'keys | @csv' ${api_output} | sed 's/"//g' > ${api_error_keys}
		hasErrors=`grep --quiet --invert errors ${api_error_keys};echo $?`
	else
		hasErrors=0
	fi

	if [[ $errorLevel -gt 0 ]] || [[ $hasErrors -gt 0 ]] || [[ "$httpResponse" != "200" ]]; then
		error_and_exit "API connection error (errorLevel $errorLevel, http response code $httpResponse, message: $message)"
	else
		token=$(echo $message | sed 's/.*{"token":"\(.*\)"}}/\1/g')
		if [ -z "${token}" ]; then
			error_and_exit "Unable to extract token from message: $message"
		fi
		log "DEBUG" "APIv2 token: ${token}"
	fi

	# Clean files
	rm -f ${api_output} ${api_return_code} ${api_error_message} ${api_error_keys}

	#
	# Call Centreon Web update API
	#
	curl "${central_ip}/centreon/api/latest/platform/updates"  \
	--silent \
	--insecure \
	--request PATCH \
	--header "X-AUTH-TOKEN: ${token}" \
	--header 'Content-Type: application/json' \
	--data '{"components":[{"name":"centreon-web"}]}' \
	--output ${api_output} \
	--write-out %{http_code} \
	> ${api_return_code} 2> ${api_error_message}

	errorLevel=$?
	httpResponse=$(cat ${api_return_code})
	message=$(cat ${api_output})
	if [[ -f ${api_output} && -s "${api_output}" ]];then
		jq --raw-output 'keys | @csv' ${api_output} | sed 's/"//g' > ${api_error_keys}
		hasErrors=`grep --quiet --invert errors ${api_error_keys};echo $?`
	else
		hasErrors=0
	fi

	if [[ $errorLevel -gt 0 ]] || [[ $hasErrors -gt 0 ]] || [[ "$httpResponse" != "204" && "$httpResponse" != "404" ]]; then
		error_and_exit "Error during update (errorLevel $errorLevel, http response code $httpResponse, message: $message)"
	else
		log "INFO" "Centreon Web update completed"
	fi

	# Clean files
	rm -f ${api_output} ${api_return_code} ${api_error_message} ${api_error_keys}

	#
	# Log in to Centreon APIv1 to get token
	#
    curl "${central_ip}/centreon/api/index.php?action=authenticate"  \
    --silent \
    --insecure \
    --request POST \
    --data "username=admin&password=${centreon_admin_password}" \
    --output ${api_output} \
    --write-out %{http_code} \
    > ${api_return_code} 2> ${api_error_message}


    # Analyse result
    errorLevel=$?
    httpResponse=$(cat ${api_return_code})
    message=$(cat ${api_output})
    if [[ -f ${api_output} && -s "${api_output}" ]];then
        jq --raw-output 'keys | @csv' ${api_output} | sed 's/"//g' > ${api_error_keys}
        hasErrors=`grep --quiet --invert errors ${api_error_keys};echo $?`
    else
        hasErrors=0
    fi

    if [[ $errorLevel -gt 0 ]] || [[ $hasErrors -gt 0 ]] || [[ "$httpResponse" != "200" ]]; then
        error_and_exit "API connection error (errorLevel $errorLevel, http response code $httpResponse, message: $message)"
    else
        tokenv1=$(echo ${message} | cut -f2 -d":" | sed -e "s/\"//g" -e "s/}//" -e 's|\\||g')
        if [ -z "${tokenv1}" ]; then
            error_and_exit "Unable to extract token from message: $message"
        fi
		log "DEBUG" "APIv1 token: ${token}"
    fi

	rm -f ${api_output} ${api_return_code} ${api_error_message} ${api_error_keys}

    #
    # Get list of installed extensions
    #
    curl "${central_ip}/centreon/api/index.php?object=centreon_module&action=list"  \
    --silent \
    --insecure \
    --request GET \
    --header "centreon-auth-token: ${tokenv1}" \
    --output ${api_output} \
    --write-out %{http_code} \
    > ${api_return_code} 2> ${api_error_message}

    # Analyse result
    errorLevel=$?
    httpResponse=$(cat ${api_return_code})
    message=$(cat ${api_output})
	if [[ -f ${api_output} && -s "${api_output}" ]];then
        jq --raw-output 'keys | @csv' ${api_output} | sed 's/"//g' > ${api_error_keys}
        hasErrors=`grep --quiet --invert errors ${api_error_keys};echo $?`
    else
        hasErrors=0
    fi

    if [[ $errorLevel -gt 0 ]] || [[ $hasErrors -gt 0 ]] || [[ "$httpResponse" != "200" ]]; then
        error_and_exit "Error during update (errorLevel $errorLevel, http response code $httpResponse, message: $message)"
    else
	    #
        # Get list of modules and update them if needed
		#
        modules=$(echo ${message} | jq '.result.module.entities[] | "\(.id)|\(.version.current)|\(.version.available)"')
        for module in ${modules}
        do
			rm -f ${api_output} ${api_return_code} ${api_error_message} ${api_error_keys}
            clear_line=$(sed -e 's/^"//' -e 's/"$//' <<< ${module})
            IFS="|" read -a module_information <<< ${clear_line}
            if [ "${module_information[1]}" != "${module_information[2]}" ]; then
                curl "${central_ip}/centreon/api/index.php?object=centreon_module&action=update&id=${module_information[0]}&type=module" \
                --silent \
                --insecure \
                --request POST \
                --header "centreon-auth-token: ${tokenv1}" \
                --output ${api_output} \
                --write-out %{http_code} \
                > ${api_return_code} 2> ${api_error_message}

                # Analyse result
                errorLevel=$?
                httpResponse=$(cat ${api_return_code})
                sub_message=$(cat ${api_output})

				if [[ -f ${api_output} && -s "${api_output}" ]];then
					jq --raw-output 'keys | @csv' ${api_output} | sed 's/"//g' > ${api_error_keys}
					hasErrors=`grep --quiet --invert errors ${api_error_keys};echo $?`
				else
					hasErrors=0
				fi

                if [[ $errorLevel -gt 0 ]] || [[ $hasErrors -gt 0 ]] || [[ "$httpResponse" != "200" ]]; then
                    error_and_exit "Error during update of ${module_information[0]} module (errorLevel $errorLevel, http response code $httpResponse, message: $sub_message)"
                else
                    status=$(echo ${sub_message} | jq '.status')
                    status_message=$(echo ${sub_message} | jq '.result.message')
                    if [ "${status}" = "false" ]; then
                        log "WARN" "Error during update of ${module_information[0]} module: ${status_message}"
                    fi
                fi
            fi
        done

		#
        # Get list of widgets and update them if needed
		#
        widgets=$(echo ${message} | jq '.result.widget.entities[] | "\(.id)|\(.version.current)|\(.version.available)"')
        for widget in ${widgets}
        do
			rm -f ${api_output} ${api_return_code} ${api_error_message} ${api_error_keys}
            clear_line=$(sed -e 's/^"//' -e 's/"$//' <<< ${widget})
            IFS="|" read -a widget_information <<< ${clear_line}
            if [ "${widget_information[1]}" != "${widget_information[2]}" ]; then
                curl "${central_ip}/centreon/api/index.php?object=centreon_module&action=update&id=${widget_information[0]}&type=widget" \
                --silent \
                --insecure \
                --request POST \
                --header "centreon-auth-token: ${tokenv1}" \
                --output ${api_output} \
                --write-out %{http_code} \
                > ${api_return_code} 2> ${api_error_message}

                # Analyse result
                errorLevel=$?
                httpResponse=$(cat ${api_return_code})
                sub_message=$(cat ${api_output})

				if [[ -f ${api_output} && -s "${api_output}" ]];then
					jq --raw-output 'keys | @csv' ${api_output} | sed 's/"//g' > ${api_error_keys}
					hasErrors=`grep --quiet --invert errors ${api_error_keys};echo $?`
				else
					hasErrors=0
				fi

                if [[ $errorLevel -gt 0 ]] || [[ $hasErrors -gt 0 ]] || [[ "$httpResponse" != "200" ]]; then
                    error_and_exit "Error during update of ${widget_information[0]} widget (errorLevel $errorLevel, http response code $httpResponse, message: $sub_message)"
                else
                    status=$(echo ${sub_message} | jq '.status')
                    status_message=$(echo ${sub_message} | jq '.result.message')
                    if [ "${status}" = "false" ]; then
                        log "WARN" "Error during update of ${widget_information[0]} widget: ${status_message}"
                    fi
                fi
            fi
        done
    fi

}
#========= end of function play_update_api()

#========= begin of function play_update()
function play_update() {
	if [ -z "${centreon_admin_password}" ]; then
		error_and_exit "Centreon admin password is not defined"
	fi

	if [[ "$version" == "21.10" || "$version" == "22.04" ]]; then
		error_and_exit "Your Centreon version is not supported for silent update, please connect to UI and perform update manually."
	else
		play_update_api
	fi
}
#========= end of function play_update()

#========= begin of function install_central()
# install the Centreon Central
#
function install_central() {

	log "INFO" "Centreon [$topology] installation from [${CENTREON_REPO}]"

	if [[ "${detected_os_release}" =~ debian-release-.* ]]; then
		$PKG_MGR install -y --no-install-recommends centreon

		if [ $? -ne 0 ]; then
			error_and_exit "Could not install Centreon (package centreon)"
		fi
	else
		# install core Centreon packages from enabled repo
		$PKG_MGR -q clean all --enablerepo="*" && $PKG_MGR -q install -y centreon --enablerepo="$CENTREON_REPO"

		if [ $? -ne 0 ]; then
			error_and_exit "Could not install Centreon (package centreon)"
		fi
	fi

	#
	# PHP
	#
	log "INFO" "PHP configuration"
	timezone=$($PHP_BIN -r '
		$timezoneName = timezone_name_from_abbr(trim(shell_exec("date \"+%Z\"")));
		if (preg_match("/Time zone: (\S+)/", shell_exec("timedatectl"), $matches)) {
			$timezoneName = $matches[1];
		}
		if (date_default_timezone_set($timezoneName) === false) {
			$timezoneName = "UTC";
		}
		echo $timezoneName;
	' 2>/dev/null)
	if [[ "${detected_os_release}" =~ debian-release-.* ]]; then
		echo "date.timezone = $timezone" >> /etc/php/8.1/mods-available/centreon.ini
	else
		echo "date.timezone = $timezone" >> $PHP_ETC/50-centreon.ini
	fi

	log "INFO" "PHP date.timezone set to [$timezone]"

	secure_mariadb_setup
}
#========= end of function install_central()

#========= begin of function install_poller()
# install the Centreon Poller
#
function install_poller() {
	log "INFO" "Poller installation from ${CENTREON_REPO}"

	if [[ "${detected_os_release}" =~ debian-release-.* ]]; then
		$PKG_MGR install -y --no-install-recommends centreon-poller

		if [ $? -ne 0 ]; then
			error_and_exit "Could not install Centreon (package centreon)"
		fi
	else
		$PKG_MGR -q clean all --enablerepo="*" && $PKG_MGR -q install -y centreon-poller-centreon-engine --enablerepo=$CENTREON_REPO
		if [ $? -ne 0 ]; then
			error_and_exit "Could not install Centreon (package centreon)"
		fi
	fi
}
#========= end of function install_poller()

#========= begin of function update_centreon_packages()
# update Centreon packages
#
function update_centreon_packages() {
	log "INFO" "Update Centreon packages using ${CENTREON_REPO}"
	if [[ "${detected_os_release}" =~ debian-release-.* ]]; then
		$PKG_MGR upgrade centreon
	else
		$PKG_MGR -q clean all --enablerepo="*" && $PKG_MGR -q update -y centreon\* --enablerepo=$CENTREON_REPO
		if [ $? -ne 0 ]; then
			error_and_exit "Could not update Centreon"
		fi
	fi
}
#========= end of function update_centreon_packages()

#========= begin of function restart_centreon_process()
# Restart Centreon process
#
function restart_centreon_process() {
	systemctl restart centreon snmpd snmptrapd
}
#========= end of function restart_centreon_process()

#========= begin of function update_after_installation()
# execute some tasks after having installed Centreon
# - update firewall config
# - enable some newly added services
#
# ## FIXME -- according to the $topology
#
function update_after_installation() {

	update_firewall_config

	enable_new_services

	if ! [[ "${detected_os_release}" =~ debian-release-.* ]]; then
		# install Centreon SELinux packages first (as getenforce is still at 0)
		$PKG_MGR -q install -y ${CENTREON_SELINUX_PACKAGES[@]} --enablerepo="$CENTREON_REPO"
		if [ $? -ne 0 ]; then
			log "ERROR" "Could not install Centreon SELinux packages"
		else
			log "INFO" "Centreon SELinux rules are installed. Please consult the documentation https://docs.centreon.com/docs/administration/secure-platform for more details."
		fi

		#then change the SELinux mode
		set_runtime_selinux_mode $selinux_mode

		set_selinux_config $selinux_mode
	fi
}
#========= end of function update_after_installation()

#========= begin of function test_password_policy()
function test_password_policy() {
	if [[ ${#centreon_admin_password} -ge 12 && "${centreon_admin_password}" == *[A-Z]* && "${centreon_admin_password}" == *[a-z]* && "${centreon_admin_password}" == *[0-9]* && "${centreon_admin_password}" == *[\!@#$%^\&*()\\[\]{}\-_+=~\`\|\:\;\"\'\<\>\,\.\/\?]* ]]; then
        log "INFO" "Password is compliant with Centreon security policy"
    else
        error_and_exit "Password is not compliant with Centreon security policy ([A-Z][a-z][0-9][\!@#$%^\&*()\\[\]{}\-_+=~\`\|\:\;\"\'\<\>\,\.\/\?]{12,})"
    fi
}
#========= end of function test_password_policy()

#####################################################
################ MAIN SCRIPT EXECUTION ##############

if [ $EUID -ne 0 ]; then
	error_and_exit "This script must be run as root"
fi

## Process the provided arguments in line
case "$1" in

-h)
    usage
	exit 0
	;;

update)
	operation="update"
	parse_subcommand_options "$@"
	;;

install)
	operation="install"
	parse_subcommand_options "$@"
	;;

*)
	log "WARN" "No provided operation: default value [$operation] will be used"
	#usage
	operation="install"
	parse_subcommand_options "$@"
	;;

esac

# Set MariaDB password from ENV or random password if not defined
if [ "$operation" == "install" ]; then
	mariadb_root_password=${ENV_MARIADB_ROOT_PASSWD:-"$(genpasswd "MariaDB user: root")"}

	if [ "$wizard_autoplay" == "true" ]; then
		# Set from ENV or random MariaDB centreon password
		mariadb_centreon_password=${ENV_MARIADB_CENTREON_PASSWD:-"$(genpasswd "MariaDB user: centreon")"}
		# Generate random password if Centreon admin password is empty
		if [ -z "${centreon_admin_password}" ]; then
			centreon_admin_password=${ENV_CENTREON_ADMIN_PASSWD:-"$(genpasswd "Centreon user: admin")"}
		else
			test_password_policy
   			echo "User defined password set for user [Centreon user: admin] is [$centreon_admin_password]" >>$tmp_passwords_file
		fi
		# Set from ENV or Administrator first name
		centreon_admin_firstname=${ENV_CENTREON_ADMIN_FIRSTNAME:-"John"}
		# Set from ENV or Administrator last name
		centreon_admin_lastname=${ENV_CENTREON_ADMIN_LASTNAME:-"Doe"}
		# Set from ENV or Administrator e-mail
		centreon_admin_email=${ENV_CENTREON_ADMIN_EMAIL:-"admin@admin.tld"}
	fi
else
	if [ "$wizard_autoplay" == "true" ]; then
		if [ -z "${centreon_admin_password}" ]; then
			error_and_exit "Centreon admin password is not defined, use '-p <centreon admin password>' option"
		else
			test_api_connection
		fi
	fi
fi

## Display all configured parameters
log "INFO" "Start to execute operation [$operation] with following configuration parameters:"
log "INFO" " topology: \t[$topology]"
log "INFO" " version: \t[$version]"
log "INFO" " repository: [$repo]"

log "WARN" "It will start in [$default_timeout_in_sec] seconds. If you don't want to wait, press any key to continue or Ctrl-C to exit"
pause "" $default_timeout_in_sec

##
# Analyze system and set the variables
##
set_required_prerequisite
##
# Check if systemd is present
##
is_systemd_present

## Start to execute
case $operation in

install)
	if ! [[ "${detected_os_release}" =~ debian-release-.* ]]; then
		setup_before_installation
	fi

	case $topology in
	central)
		CENTREON_SELINUX_PACKAGES=(centreon-common-selinux centreon-web-selinux centreon-broker-selinux centreon-engine-selinux centreon-gorgoned-selinux centreon-plugins-selinux)
		install_central
		CENTREON_DOC_URL="https://docs.centreon.com/docs/installation/web-and-post-installation/#web-installation"
		;;

	poller)
		CENTREON_SELINUX_PACKAGES=(centreon-common-selinux centreon-broker-selinux centreon-engine-selinux centreon-gorgoned-selinux centreon-plugins-selinux)
		install_poller
		CENTREON_DOC_URL="https://docs.centreon.com/docs/monitoring/monitoring-servers/add-a-poller-to-configuration/"
		;;
	esac

	update_after_installation

	if [ "$topology" == "central" ] && [ "$wizard_autoplay" == "true" ]; then
		play_install_wizard
		log "INFO" "Log in to Centreon web interface via the URL: http://$central_ip/centreon"
	else
		log "INFO" "Follow the steps described in Centreon documentation: $CENTREON_DOC_URL"
	fi

	log "INFO" "Centreon [$topology] successfully installed !"
	;;

update)
	case $topology in

	central)
		update_centreon_packages
		if [ "$wizard_autoplay" == "true" ]; then
			play_update
			restart_centreon_process
			log "INFO" "Log in to Centreon web interface via the URL: http://$central_ip/centreon"
		else
			CENTREON_DOC_URL="https://docs.centreon.com/docs/update/update-centreon-platform/#update-the-centreon-solution"
			log "INFO" "Follow the steps described in Centreon documentation: $CENTREON_DOC_URL"
		fi
		;;
	poller)
		CENTREON_DOC_URL=""
		update_centreon_packages
		restart_centreon_process
		;;
	esac

	log "INFO" "Centreon [$topology] successfully updated !"
	;;

esac

## Major change - remind it again (in case of log level is ERROR)
if [ -e $tmp_passwords_file ] && [ "$topology" == "central" ] && [ "$operation" = "install" ]; then
	# Move the tmp file to the dest file
	mv $tmp_passwords_file $passwords_file
	echo
	echo "****** IMPORTANT ******"
	if [ "$wizard_autoplay" == "true" ]; then
		echo "As you will need passwords for users such as MariaDB [root,centreon] and Centreon [admin], random passwords are generated"
	else
		echo "As you will need password for user MariaDB [root], random password are generated"
	fi
	echo "Passwords are currently saved in [$passwords_file]"
	cat $passwords_file
	echo
	echo "Please save them securely and then delete this file!"
	echo
fi
if [ -e $tmp_passwords_file ] && [ "$operation" = "update" ]; then
	rm -f $tmp_passwords_file
fi

exit 0
