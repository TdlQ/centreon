import { makeStyles } from 'tss-react/mui';

export const usePanelHeaderStyles = makeStyles()((theme) => ({
  description: {
    marginBottom: theme.spacing(1)
  },
  panelActionsIcons: {
    columnGap: theme.spacing(2),
    display: 'flex',
    flexDirection: 'row',
    marginRight: theme.spacing(1)
  },
  panelContent: {
    height: `100%`,
    overflow: 'auto'
  },
  panelContentWithDescription: {
    height: `calc(100% - ${theme.spacing(2.75)})`,
    overflow: 'auto'
  },
  panelHeader: {
    '& span': {
      fontSize: theme.typography.body1.fontSize,
      fontWeight: theme.typography.fontWeightMedium,
      lineHeight: 1
    },
    height: theme.spacing(4.5),
    padding: theme.spacing(0),
    paddingTop: theme.spacing(1.5)
  },
  panelTitle: {
    fontSize: '1.3rem',
    fontWeight: theme.typography.fontWeightBold
  }
}));

export const useAddWidgetPanelStyles = makeStyles()((theme) => ({
  addWidgetPanel: {
    alignItems: 'center',
    display: 'flex',
    flexDirection: 'column',
    height: '100%',
    justifyContent: 'space-evenly',
    margin: theme.spacing(1, 2)
  },
  avatar: {
    alignSelf: 'center',
    backgroundColor: theme.palette.primary.main,
    height: theme.spacing(10),
    width: theme.spacing(10)
  }
}));
