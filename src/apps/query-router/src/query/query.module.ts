/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   query.module.ts                                    :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 21:16:42 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { Module } from '@nestjs/common';
import { ConfigModule } from '@nestjs/config';
import { HttpModule } from '@nestjs/axios';
import { QueryController } from './query.controller';
import { TxnController } from './txn.controller';
import { EnginesController } from './engines.controller';
import { CapabilitiesController } from './capabilities.controller';
import { SchemaController } from './schema.controller';
import { AutomationsController } from './automations.controller';
import { QueryService } from './query.service';
import { OutboxService } from './outbox.service';
import { AutomationsService } from './automations.service';
import { RealtimePublisherService } from './realtime-publisher.service';
import { SchemaService } from './schema.service';
import { RustDataPlaneProxy } from '../proxy/rust-data-plane.proxy';
import { GraphController } from '../graph/graph.controller';
import { GraphService } from '../graph/graph.service';
// All TS engines have been removed. The 5 real engines (postgresql/mongodb/
// mysql/redis/http) forward to the Rust data-plane-router via
// RustDataPlaneProxy (see parity-probe.sh). The 6 former stubs
// (jdbc/cassandra/neo4j/elasticsearch/qdrant/influx) were deleted because
// they returned NotImplemented on most operations and advertising them in
// /engines misled SDK consumers. To add a new engine: write a Rust adapter
// in data-plane-pool and forward it via the proxy.

@Module({
  imports: [ConfigModule, HttpModule],
  controllers: [
    QueryController,
    TxnController,
    EnginesController,
    CapabilitiesController,
    SchemaController,
    AutomationsController,
    GraphController,
  ],
  providers: [
    QueryService,
    OutboxService,
    AutomationsService,
    RealtimePublisherService,
    RustDataPlaneProxy,
    SchemaService,
    GraphService,
  ],
})
export class QueryModule {}
