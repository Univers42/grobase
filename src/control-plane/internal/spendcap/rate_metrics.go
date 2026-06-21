/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   rate_metrics.go                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/21 04:56:07 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/21 04:56:08 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

package spendcap

// billableMetrics is the closed set of priceable dimensions, mirroring
// metering.billableMetrics so the spend model uses B1's frozen metric vocabulary
// (store.go fieldMetric). Returned from a func (not a package var) so the package
// declares no global.
func billableMetrics() []string {
	return []string{
		"query.count", "query.rows", "write.rows",
		"storage.bytes", "realtime.minutes", "function.invocations",
	}
}

// billableMetricEnv maps a priceable dimension → the env var carrying its
// cents-per-unit rate. Extending to a new dimension is one case here + the metric
// in billableMetrics + the env in the deployment. Unknown → "".
func billableMetricEnv(metric string) string {
	switch metric {
	case "query.count":
		return "SPEND_RATE_QUERY_COUNT"
	case "query.rows":
		return "SPEND_RATE_QUERY_ROWS"
	case "write.rows":
		return "SPEND_RATE_WRITE_ROWS"
	case "storage.bytes":
		return "SPEND_RATE_STORAGE_BYTES"
	case "realtime.minutes":
		return "SPEND_RATE_REALTIME_MINUTES"
	case "function.invocations":
		return "SPEND_RATE_FUNCTION_INVOCATIONS"
	}
	return ""
}
