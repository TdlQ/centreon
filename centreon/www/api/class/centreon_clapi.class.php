<?php
/*
 * Copyright 2005-2015 Centreon
 * Centreon is developped by : Julien Mathis and Romain Le Merlus under
 * GPL Licence 2.0.
 *
 * This program is free software; you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation ; either version 2 of the License.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
 * PARTICULAR PURPOSE. See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program; if not, see <http://www.gnu.org/licenses>.
 *
 * Linking this program statically or dynamically with other modules is making a
 * combined work based on this program. Thus, the terms and conditions of the GNU
 * General Public License cover the whole combination.
 *
 * As a special exception, the copyright holders of this program give Centreon
 * permission to link this program with independent modules to produce an executable,
 * regardless of the license terms of these independent modules, and to copy and
 * distribute the resulting executable under terms of Centreon choice, provided that
 * Centreon also meet, for each linked independent module, the terms  and conditions
 * of the license of that module. An independent module is a module which is not
 * derived from this program. If you modify this program, you may extend this
 * exception to your version of the program, but you are not obliged to do so. If you
 * do not wish to do so, delete this exception statement from your version.
 *
 * For more information : contact@centreon.com
 *
 */

require_once __DIR__ . '/../../include/common/common-Func.php';
require_once dirname(__FILE__) . "/webService.class.php";

define('_CLAPI_LIB_', _CENTREON_PATH_ . '/lib');
define('_CLAPI_CLASS_', _CENTREON_PATH_ . '/www/class/centreon-clapi');

set_include_path(implode(PATH_SEPARATOR, array(
    _CENTREON_PATH_ . '/lib',
    _CENTREON_PATH_ . '/www/class/centreon-clapi',
    get_include_path()
)));

require_once _CENTREON_PATH_ . '/www/class/centreon-clapi/centreonAPI.class.php';

/**
 * Class wrapper for CLAPI to expose in REST
 */
class CentreonClapi extends CentreonWebService implements CentreonWebServiceDiInterface
{
    /**
     * @var \Pimple\Container
     */
    private $dependencyInjector;

    /**
     * {@inheritdoc}
     */
    public function finalConstruct(\Pimple\Container $dependencyInjector)
    {
        $this->dependencyInjector = $dependencyInjector;
    }

    /**
     * Post
     *
     * @global \Centreon $centreon
     * @global array $conf_centreon
     * @return array
     * @throws \RestBadRequestException
     * @throws \RestNotFoundException
     * @throws \RestConflictException
     * @throws \RestInternalServerErrorException
     */
    public function postAction()
    {
        global $centreon;
        global $conf_centreon;

        $dbConfig['host'] = $conf_centreon['hostCentreon'];
        $dbConfig['username'] = $conf_centreon['user'];
        $dbConfig['password'] = $conf_centreon['password'];
        $dbConfig['dbname'] = $conf_centreon['db'];
        if (isset($conf_centreon['port'])) {
            $dbConfig['port'] = $conf_centreon['port'];
        } elseif ($p = strstr($dbConfig['host'], ':')) {
            $p = substr($p, 1);
            if (is_numeric($p)) {
                $dbConfig['port'] = $p;
            }
        }

        $db = $this->dependencyInjector['configuration_db'];
        $db_storage = $this->dependencyInjector['realtime_db'];
        $username = $centreon->user->alias;

        CentreonClapi\CentreonUtils::setUserName($username);

        if (false === isset($this->arguments['action'])) {
            throw new RestBadRequestException("Bad parameters");
        }

        /* Prepare options table */
        $action = $this->arguments['action'];

        $options = array();
        if (isset($this->arguments['object'])) {
            $options['o'] = $this->arguments['object'];
        }

        if (isset($this->arguments['values'])) {
            if (is_array($this->arguments['values'])) {
                $options['v'] = join(';', $this->arguments['values']);
            } else {
                $options['v'] = $this->arguments['values'];
            }
        }

        /* Load and execute clapi option */
        try {
            $clapi = new \CentreonClapi\CentreonAPI(
                $username,
                '',
                $action,
                _CENTREON_PATH_,
                $options,
                $this->dependencyInjector
            );
            ob_start();
            $retCode = $clapi->launchAction(false);
            $contents = ob_get_contents();
            ob_end_clean();
        } catch (\CentreonClapi\CentreonClapiException $e) {
            $message = $e->getMessage();
            if (strpos($message, \CentreonClapi\CentreonObject::UNKNOWN_METHOD) === 0) {
                throw new RestNotFoundException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::MISSINGPARAMETER) === 0) {
                throw new RestBadRequestException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::MISSINGNAMEPARAMETER) === 0) {
                throw new RestBadRequestException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::OBJECTALREADYEXISTS) === 0) {
                throw new RestConflictException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::OBJECT_NOT_FOUND) === 0) {
                throw new RestNotFoundException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::NAMEALREADYINUSE) === 0) {
                throw new RestConflictException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::UNKNOWNPARAMETER) === 0) {
                throw new RestBadRequestException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::OBJECTALREADYLINKED) === 0) {
                throw new RestConflictException($message);
            }
            if (strpos($message, \CentreonClapi\CentreonObject::OBJECTNOTLINKED) === 0) {
                throw new RestBadRequestException($message);
            }
            throw new RestInternalServerErrorException($message);
        }
        if ($retCode != 0) {
            $contents = trim($contents);
            if (preg_match('/^Object ([\w\d ]+) not found in Centreon API.$/', $contents)) {
                throw new RestBadRequestException($contents);
            }
            throw new RestInternalServerErrorException($contents);
        }


        $delim_in_first_line = preg_match("/^.*;.*(?:\n|$)/", $contents);
        if ($delim_in_first_line) {
            $result = parse_csv($contents);
            if ($result == false) {
                throw new RestInternalServerErrorException($contents);
            }

            $last_record = end($result);
            if ($last_record && strpos($last_record[0], 'Return code end :') === 0) {
                array_pop($result);
            }

            $headers_nr = count($result[0]);
            foreach ($result as &$record) {
                if (count($record) > $headers_nr) {
                    $record[$headers_nr - 1] = implode(';', array_slice($record, $headers_nr - 1));
                    $record = array_slice($record, 0, $headers_nr);
                }
                foreach ($record as $field_name => &$field_value) {
                    if (strpos($field_value, '|') !== false) {
                        $field_value = explode('|', $field_value);
                    }
                }
            }

            csv_to_associative_array($result);

        } else {
            $result = array();
            foreach (explode("\n", $contents) as &$line) {
                if (trim($line) !== '' && strpos($line, 'Return code end :') !== 0) {
                    $result[] = $line;
                }
            }
        }

        $return = array();
        $return['result'] = $result;

        return $return;
    }

    /**
     * Authorize to access to the action
     *
     * @param string $action The action name
     * @param \CentreonUser $user The current user
     * @param boolean $isInternal If the api is call in internal
     * @return boolean If the user has access to the action
     */
    public function authorize($action, $user, $isInternal = false)
    {
        if (
            parent::authorize($action, $user, $isInternal)
            || ($user && $user->is_admin())
        ) {
            return true;
        }

        return false;
    }

    /**
     * Removes carriage returns from $item if string
     * @param $item variable to check
     */
    private function clearCarriageReturns(&$item)
    {
        $item = (is_string($item)) ? str_replace(array("\n", "\t", "\r", "<br/>"), '', $item) : $item;
    }
}
