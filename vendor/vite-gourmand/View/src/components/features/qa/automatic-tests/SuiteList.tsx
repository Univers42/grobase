/**
 * SuiteList - Shows test suites grouped by type (Unit/E2E) with expandable tests
 */

import React, { useState } from 'react';
import type { TestSuite, AutoTestStatus } from './types';
import './SuiteList.css';

/** Get status icon for test result */
function getStatusIcon(status: AutoTestStatus): string {
  switch (status) {
    case 'passed':
      return '✓';
    case 'failed':
      return '✕';
    default:
      return '○';
  }
}

interface SuiteListProps {
  suites: TestSuite[];
  onRunSuite?: (suiteName: string) => void;
  onRunType?: (type: 'unit' | 'e2e' | 'custom' | 'postman') => void;
  isRunning?: boolean;
}

interface GroupedSuites {
  unit: TestSuite[];
  e2e: TestSuite[];
  custom: TestSuite[];
  postman: TestSuite[];
}

function groupSuitesByType(suites: TestSuite[]): GroupedSuites {
  return suites.reduce<GroupedSuites>(
    (acc, suite) => {
      if (suite.type === 'e2e') {
        acc.e2e.push(suite);
      } else if (suite.type === 'custom') {
        acc.custom.push(suite);
      } else if (suite.type === 'postman') {
        acc.postman.push(suite);
      } else {
        acc.unit.push(suite);
      }
      return acc;
    },
    { unit: [], e2e: [], custom: [], postman: [] },
  );
}

interface GroupStats {
  suites: number;
  tests: number;
  passed: number;
  failed: number;
  duration: number;
}

function calculateGroupStats(suites: TestSuite[]): GroupStats {
  return suites.reduce(
    (acc, suite) => ({
      suites: acc.suites + 1,
      tests: acc.tests + suite.tests.length,
      passed: acc.passed + suite.totalPassed,
      failed: acc.failed + suite.totalFailed,
      duration: acc.duration + suite.totalDuration,
    }),
    { suites: 0, tests: 0, passed: 0, failed: 0, duration: 0 },
  );
}

export function SuiteList({
  suites,
  onRunSuite: _onRunSuite,
  onRunType,
  isRunning,
}: Readonly<SuiteListProps>) {
  const [expandedGroups, setExpandedGroups] = useState<Set<string>>(
    new Set(['unit', 'e2e', 'custom', 'postman']),
  );
  const [expandedSuites, setExpandedSuites] = useState<Set<string>>(new Set());

  const toggleGroup = (groupName: string) => {
    setExpandedGroups((prev) => {
      const next = new Set(prev);
      if (next.has(groupName)) {
        next.delete(groupName);
      } else {
        next.add(groupName);
      }
      return next;
    });
  };

  const toggleSuite = (name: string) => {
    setExpandedSuites((prev) => {
      const next = new Set(prev);
      if (next.has(name)) {
        next.delete(name);
      } else {
        next.add(name);
      }
      return next;
    });
  };

  // Group suites by type
  const grouped = groupSuitesByType(suites);
  const unitStats = calculateGroupStats(grouped.unit);
  const e2eStats = calculateGroupStats(grouped.e2e);
  const customStats = calculateGroupStats(grouped.custom);
  const postmanStats = calculateGroupStats(grouped.postman);

  // Total stats
  const totalTests = unitStats.tests + e2eStats.tests + customStats.tests + postmanStats.tests;
  const totalPassed = unitStats.passed + e2eStats.passed + customStats.passed + postmanStats.passed;
  const totalFailed = unitStats.failed + e2eStats.failed + customStats.failed + postmanStats.failed;

  // Show loading state when running with no data
  if (isRunning && suites.length === 0) {
    return (
      <div className="suite-list">
        <div className="suite-list__loading">
          <div className="suite-list__loading-animation">
            <svg viewBox="0 0 120 120" className="suite-list__loader-svg">
              {/* Background circle */}
              <circle
                cx="60"
                cy="60"
                r="54"
                fill="none"
                stroke="var(--color-border, #e5e7eb)"
                strokeWidth="2"
              />
              {/* Animated arc */}
              <circle
                cx="60"
                cy="60"
                r="54"
                fill="none"
                stroke="var(--color-primary, #722F37)"
                strokeWidth="4"
                strokeLinecap="round"
                strokeDasharray="85 255"
                className="suite-list__loader-ring"
              />

              {/* Central test tube / beaker shape */}
              <g className="suite-list__loader-beaker">
                <path
                  d="M52 35 L52 55 L45 75 Q43 82 50 85 L70 85 Q77 82 75 75 L68 55 L68 35"
                  fill="none"
                  stroke="var(--color-primary, #722F37)"
                  strokeWidth="3"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
                {/* Liquid bubbles */}
                <circle
                  cx="55"
                  cy="72"
                  r="4"
                  fill="var(--color-success, #059669)"
                  className="suite-list__bubble suite-list__bubble--1"
                />
                <circle
                  cx="62"
                  cy="68"
                  r="3"
                  fill="var(--color-warning, #d97706)"
                  className="suite-list__bubble suite-list__bubble--2"
                />
                <circle
                  cx="66"
                  cy="75"
                  r="3.5"
                  fill="var(--color-primary, #722F37)"
                  className="suite-list__bubble suite-list__bubble--3"
                />
              </g>

              {/* Orbiting checkmark and X */}
              <g className="suite-list__loader-orbit">
                <circle cx="60" cy="8" r="8" fill="var(--color-success, #059669)" />
                <path
                  d="M56 8 L59 11 L65 5"
                  stroke="white"
                  strokeWidth="2"
                  fill="none"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                />
              </g>
              <g className="suite-list__loader-orbit suite-list__loader-orbit--reverse">
                <circle cx="60" cy="8" r="7" fill="var(--color-error, #dc2626)" />
                <path
                  d="M57 5 L63 11 M63 5 L57 11"
                  stroke="white"
                  strokeWidth="2"
                  fill="none"
                  strokeLinecap="round"
                />
              </g>
            </svg>
          </div>
          <h3 className="suite-list__loading-title">Executing Tests...</h3>
          <p className="suite-list__loading-text">
            Running all test suites. This may take a minute or two.
          </p>
        </div>
      </div>
    );
  }

  if (suites.length === 0) {
    return (
      <div className="suite-list">
        <div className="suite-list__empty">
          <div className="suite-list__empty-icon">🧪</div>
          <h3 className="suite-list__empty-title">No Test Results Yet</h3>
          <p className="suite-list__empty-text">
            Click the <strong>"Run All Tests"</strong> button above to execute your test suites.
          </p>
          <div className="suite-list__empty-hint">
            💡 Tests are executed on the backend and results are cached for quick viewing
          </div>
        </div>
      </div>
    );
  }

  const renderGroup = (
    type: 'unit' | 'e2e' | 'custom' | 'postman',
    label: string,
    groupSuites: TestSuite[],
    stats: GroupStats,
  ) => {
    const isExpanded = expandedGroups.has(type);
    const allPassed = stats.failed === 0;

    return (
      <div key={type} className="suite-list__group">
        {/* Group Header */}
        <div
          className={`suite-list__group-header ${allPassed ? 'suite-list__group-header--passed' : 'suite-list__group-header--failed'}`}
        >
          <button
            className="suite-list__group-toggle"
            onClick={() => toggleGroup(type)}
            aria-label={isExpanded ? 'Collapse group' : 'Expand group'}
          >
            {isExpanded ? '▼' : '▶'}
          </button>

          <span className="suite-list__group-title">{label}</span>

          <span className="suite-list__group-stats">
            <span className="suite-list__group-stat">{stats.suites} suites</span>
            <span className="suite-list__group-divider">•</span>
            <span className="suite-list__group-stat">{stats.tests} tests</span>
            <span className="suite-list__group-divider">•</span>
            <span className="suite-list__group-stat suite-list__group-stat--passed">
              ✓ {stats.passed}
            </span>
            <span className="suite-list__group-divider">•</span>
            <span className="suite-list__group-stat suite-list__group-stat--failed">
              ✕ {stats.failed}
            </span>
          </span>

          <button
            className="suite-list__group-run-btn"
            onClick={() => onRunType?.(type)}
            disabled={isRunning}
            title={`Run all ${label}`}
          >
            ▶ Run {label}
          </button>
        </div>

        {/* Group Content */}
        {isExpanded && groupSuites.length > 0 && (
          <div className="suite-list__group-content">
            <table className="suite-list__table">
              <thead className="suite-list__head">
                <tr>
                  <th className="suite-list__th suite-list__th--expand"></th>
                  <th className="suite-list__th suite-list__th--name">Suite</th>
                  <th className="suite-list__th suite-list__th--tests">Tests</th>
                  <th className="suite-list__th suite-list__th--status">Status</th>
                  <th className="suite-list__th suite-list__th--duration">Duration</th>
                </tr>
              </thead>
              <tbody>
                {groupSuites.map((suite, index) => {
                  const isSuiteExpanded = expandedSuites.has(suite.name);
                  const suiteAllPassed = suite.totalFailed === 0;
                  const fileName = suite.name.split('/').pop() || suite.name;

                  return (
                    <React.Fragment key={suite.name}>
                      <tr
                        className={`suite-list__row ${index % 2 === 1 ? 'suite-list__row--even' : ''}`}
                      >
                        <td className="suite-list__td suite-list__td--expand">
                          {suite.tests.length > 0 && (
                            <button
                              className="suite-list__expand-btn"
                              onClick={() => toggleSuite(suite.name)}
                              aria-label={isSuiteExpanded ? 'Collapse' : 'Expand'}
                            >
                              {isSuiteExpanded ? '▼' : '▶'}
                            </button>
                          )}
                        </td>
                        <td className="suite-list__td suite-list__td--name">
                          <span className="suite-list__filename">{fileName}</span>
                        </td>
                        <td className="suite-list__td suite-list__td--tests">
                          <span className="suite-list__test-count">{suite.tests.length}</span>
                        </td>
                        <td className="suite-list__td suite-list__td--status">
                          <span
                            className={`suite-list__status ${suiteAllPassed ? 'suite-list__status--passed' : 'suite-list__status--failed'}`}
                          >
                            {suiteAllPassed ? '✓ PASS' : `✕ ${suite.totalFailed} FAIL`}
                          </span>
                        </td>
                        <td className="suite-list__td suite-list__td--duration">
                          {suite.totalDuration}ms
                        </td>
                      </tr>

                      {/* Expanded tests */}
                      {isSuiteExpanded &&
                        suite.tests.map((test) => (
                          <tr key={test.id} className="suite-list__row suite-list__row--test">
                            <td className="suite-list__td"></td>
                            <td className="suite-list__td suite-list__td--test-name" colSpan={2}>
                              <span
                                className={`suite-list__test-icon suite-list__test-icon--${test.status}`}
                              >
                                {getStatusIcon(test.status)}
                              </span>
                              <span className="suite-list__test-title">{test.name}</span>
                            </td>
                            <td className="suite-list__td suite-list__td--test-status">
                              <span
                                className={`suite-list__test-badge suite-list__test-badge--${test.status}`}
                              >
                                {test.status}
                              </span>
                            </td>
                            <td className="suite-list__td suite-list__td--test-duration">
                              {test.duration ?? 0}ms
                            </td>
                          </tr>
                        ))}
                    </React.Fragment>
                  );
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    );
  };

  return (
    <div className="suite-list">
      {/* Summary header */}
      <div className="suite-list__summary">
        <span className="suite-list__summary-item">
          <strong>{suites.length}</strong> suites
        </span>
        <span className="suite-list__summary-divider">•</span>
        <span className="suite-list__summary-item">
          <strong>{totalTests}</strong> tests
        </span>
        <span className="suite-list__summary-divider">•</span>
        <span className="suite-list__summary-item suite-list__summary-item--passed">
          ✓ {totalPassed} passed
        </span>
        <span className="suite-list__summary-divider">•</span>
        <span className="suite-list__summary-item suite-list__summary-item--failed">
          ✕ {totalFailed} failed
        </span>
      </div>

      {/* Groups */}
      <div className="suite-list__groups">
        {grouped.unit.length > 0 && renderGroup('unit', 'Unit Tests', grouped.unit, unitStats)}
        {grouped.e2e.length > 0 && renderGroup('e2e', 'E2E Tests', grouped.e2e, e2eStats)}
        {grouped.custom.length > 0 &&
          renderGroup('custom', 'Custom Tests', grouped.custom, customStats)}
        {grouped.postman.length > 0 &&
          renderGroup('postman', 'Postman Tests', grouped.postman, postmanStats)}
      </div>
    </div>
  );
}
