/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   otel.bootstrap.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 16:10:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 16:38:12 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

type NodeSdkConstructor = new (options: Record<string, unknown>) => { start: () => void; shutdown: () => Promise<void> };

let started = false;

export function startOtel(serviceName: string): void {
  if (started || process.env['OTEL_SDK_DISABLED'] === 'true') return;
  started = true;
  process.env['OTEL_SERVICE_NAME'] = process.env['OTEL_SERVICE_NAME'] ?? serviceName;

  try {
    const { NodeSDK } = require('@opentelemetry/sdk-node') as { NodeSDK: NodeSdkConstructor };
    const { OTLPTraceExporter } = require('@opentelemetry/exporter-trace-otlp-http') as {
      OTLPTraceExporter: new (options: Record<string, unknown>) => unknown;
    };
    const { getNodeAutoInstrumentations } = require('@opentelemetry/auto-instrumentations-node') as {
      getNodeAutoInstrumentations: () => unknown;
    };

    const sdk = new NodeSDK({
      serviceName,
      traceExporter: new OTLPTraceExporter({
        url: process.env['OTEL_EXPORTER_OTLP_ENDPOINT'] ?? 'http://otel-collector:4318/v1/traces',
      }),
      instrumentations: [getNodeAutoInstrumentations()],
    });

    sdk.start();
    process.once('SIGTERM', () => {
      void sdk.shutdown().finally(() => process.exit(0));
    });
  } catch (error) {
    console.warn(JSON.stringify({ service: serviceName, event: 'otel_disabled', error: (error as Error).message }));
  }
}