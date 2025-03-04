@REQ_MON-24338
Feature: Configuring metrics graph widget
  As a Centreon User with dashboard update rights,
  I need to configure a widget containing a metrics graph on a dashboard
  To manipulate the properties of the metrics graph Widget and test the outcome of each manipulation.

  @TEST_MON-23847
  Scenario: Creating and configuring a new Metrics Graph widget on a dashboard
    Given a dashboard in the dashboard administrator user's dashboard library
    When the dashboard administrator user selects the option to add a new widget
    And selects the widget type "Metrics graph"
    Then configuration properties for the Metrics graph widget are displayed
    When the dashboard administrator user selects a resource and a metric for the widget to report on
    Then a graph with a single bar is displayed in the widget's preview
    And this bar represents the evolution of the selected metric over the default period of time
    When the user saves the Metrics Graph widget
    Then the Metrics Graph widget is added to the dashboard's layout
    And the information about the selected metric is displayed

  @TEST_MON-23901
  Scenario: Editing the thresholds of a Metrics Graph widget
    Given a dashboard featuring having Metrics Graph widget
    When the dashboard administrator user updates the custom warning threshold
    Then the Metrics Graph widget is refreshed to display the updated warning threshold horizontal bar
    When the dashboard administrator user updates the custom critical threshold
    Then the Metrics Graph widget is refreshed to display the updated critical threshold horizontal bar
    When the dashboard administrator user updates a threshold to a value beyond the default range of the Y-axis
    Then the Y-axis of the Metrics Graph widget is updated to reflect the change in threshold

  @TEST_MON-23934
  Scenario: Deleting a Metrics Graph widget
    Given a dashboard featuring two Metrics Graph widgets
    When the dashboard administrator user deletes one of the Metrics Graph widgets
    Then only the contents of the other Metrics Graph widget are displayed

  @TEST_MON-23933
  Scenario: Duplicating a Metrics Graph widget
    Given a dashboard that includes a configured Metrics Graph widget
    When the dashboard administrator user duplicates the Metrics Graph widget
    Then a second Metrics Graph widget is displayed on the dashboard
    And the second widget has the same properties as the first widget

  @TEST_MON-23932
  Scenario: Adding new hosts in the Metrics Graph widget representation
    Given a dashboard featuring a configured Metrics Graph widget
    When the dashboard administrator user selects a metric with a different unit than the initial metric in the dataset selection
    Then additional bars representing the metric behavior of these metrics are added to the Metrics Graph widget
    And an additional Y-axis based on the unit of these additional bars is displayed
    And the thresholds are automatically hidden

  @TEST_MON-50539
  Scenario: Adding Metrics graph widget with more than two metric units
    Given a dashboard with a configured Metrics Graph widget
    When the dashboard administrator selects more than two metric units
    Then a message should be displayed indicating that the user can only select a maximum of two metric units
