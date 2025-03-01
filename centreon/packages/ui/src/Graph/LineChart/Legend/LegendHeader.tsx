import { Typography } from '@mui/material';

import {
  EllipsisTypography,
  formatMetricName,
  formatMetricValue
} from '../../..';
import { Line } from '../../common/timeSeries/models';
import { Tooltip } from '../../../components';

import { useLegendHeaderStyles } from './Legend.styles';
import { LegendDisplayMode } from './models';
import LegendContent from './LegendContent';

interface Props {
  color: string;
  disabled?: boolean;
  line: Line;
  minMaxAvg?;
  value?: string | null;
}

const LegendHeader = ({
  line,
  color,
  disabled,
  value,
  minMaxAvg
}: Props): JSX.Element => {
  const { classes, cx } = useLegendHeaderStyles({ color });

  const { name, legend } = line;

  const metricName = formatMetricName({ legend, name });

  const legendName = legend || name;

  return (
    <div className={classes.container}>
      <Tooltip
        followCursor={false}
        label={
          minMaxAvg ? (
            <div>
              <Typography>{legendName}</Typography>
              <div className={classes.minMaxAvgContainer}>
                {minMaxAvg.map(({ label, value: subValue }) => (
                  <LegendContent
                    data={formatMetricValue({
                      unit: line.unit,
                      value: subValue
                    })}
                    key={label}
                    label={label}
                  />
                ))}
              </div>
            </div>
          ) : (
            legendName
          )
        }
        placement="top"
      >
        <div className={classes.markerAndLegendName}>
          <div className={cx(classes.icon, { [classes.disabled]: disabled })} />
          <EllipsisTypography
            className={cx(classes.text, classes.legendName)}
            data-mode={
              value ? LegendDisplayMode.Compact : LegendDisplayMode.Normal
            }
          >
            {metricName}
          </EllipsisTypography>
        </div>
      </Tooltip>
    </div>
  );
};

export default LegendHeader;
