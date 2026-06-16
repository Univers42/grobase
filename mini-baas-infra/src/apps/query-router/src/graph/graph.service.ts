import { Injectable, Logger } from '@nestjs/common';
import { VerifiedRequestIdentity } from '@mini-baas/common';
import { ExecuteQueryDto } from '../query/dto/query.dto';
import { QueryService } from '../query/query.service';
import { GraphOverviewDto, GraphRequestDto } from './graph.dto';
import { generatedEdges } from './graph.generators';
import {
  EdgeRecord,
  formatNodeId,
  GraphNode,
  GraphResponse,
  parseNodeId,
  ResourceRef,
  toEdgeRecord,
} from './graph.types';

type QueryRows = { rows?: Array<Record<string, unknown>> };
interface Ctx {
  requestId?: string;
  identity?: VerifiedRequestIdentity;
}
interface GraphAcc {
  nodes: Map<string, GraphNode>;
  edges: Map<string, EdgeRecord>;
  visited: Set<string>;
}

/**
 * Assembles a node-link subgraph by composing the existing `/v1/query` reads —
 * no new engine work, no cross-database join. Nodes and their neighbours come
 * from `get`/`list`; edges come from the dedicated `edges` mount (the primary
 * edge source). Every read goes through `QueryService.executeQuery`, so the
 * per-resource permission check and tenant scoping apply to the graph for free:
 * a node the caller cannot read is simply omitted (the graph shows only what
 * you may see). A cross-mount subgraph is several atomic reads, so its honesty
 * tier is `subgraph_eventual` (no global snapshot across engines — by design).
 */
@Injectable()
export class GraphService {
  private readonly logger = new Logger(GraphService.name);
  private static readonly MAX_DEPTH = 3;
  private static readonly EDGE_FANOUT = 1000;
  private static readonly DEFAULT_OVERVIEW_LIMIT = 500;
  private static readonly MAX_OVERVIEW_LIMIT = 2000;

  constructor(private readonly query: QueryService) {}

  /**
   * The global (focus-less) graph: list every node from the requested resources
   * (bounded per resource) plus every edge from the `edges` mount, then layer the
   * secondary generators. This is the Obsidian "whole vault" view — still pure
   * orchestration over `/v1/query`, still per-permission (unreadable rows are
   * dropped), and always `subgraph_eventual` (it spans several reads/mounts).
   */
  async overview(req: GraphOverviewDto, userId: string, ctx: Ctx): Promise<GraphResponse> {
    const limit = Math.min(
      Math.max(req.limit ?? GraphService.DEFAULT_OVERVIEW_LIMIT, 1),
      GraphService.MAX_OVERVIEW_LIMIT,
    );
    const edgesTable = req.edgesTable ?? 'edges';
    const nodes = new Map<string, GraphNode>();
    for (const ref of this.validResources(req.resources)) {
      for (const node of await this.listNodes(ref.dbId, ref.table, limit, userId, ctx)) {
        nodes.set(node.id, node);
      }
    }
    const edges = new Map<string, EdgeRecord>();
    for (const edge of await this.listAllEdges(req.edgesDbId, edgesTable, userId, ctx)) {
      edges.set(edge.id, edge);
    }
    for (const node of nodes.values()) {
      for (const edge of generatedEdges(node, req.generators)) edges.set(edge.id, edge);
    }
    return {
      depth: 0,
      nodes: [...nodes.values()],
      edges: [...edges.values()],
      guarantee: 'subgraph_eventual',
    };
  }

  async deriveGraph(req: GraphRequestDto, userId: string, ctx: Ctx): Promise<GraphResponse> {
    const depth = Math.min(Math.max(req.depth ?? 1, 0), GraphService.MAX_DEPTH);
    const edgesTable = req.edgesTable ?? 'edges';
    const acc: GraphAcc = { nodes: new Map(), edges: new Map(), visited: new Set() };
    let frontier = [req.focus];

    for (let d = 0; d <= depth; d++) {
      frontier = await this.expandFrontier(frontier, d < depth, req, edgesTable, userId, ctx, acc);
    }

    return {
      focus: req.focus,
      depth,
      nodes: [...acc.nodes.values()],
      edges: [...acc.edges.values()],
      guarantee: depth === 0 ? 'per_node_atomic' : 'subgraph_eventual',
    };
  }

  /** Visit each node in `frontier`, record it, and (when `expand`) return the
   *  next ring of unvisited neighbour ids. */
  private async expandFrontier(
    frontier: string[],
    expand: boolean,
    req: GraphRequestDto,
    edgesTable: string,
    userId: string,
    ctx: Ctx,
    acc: GraphAcc,
  ): Promise<string[]> {
    const next: string[] = [];
    for (const nodeId of frontier) {
      if (acc.visited.has(nodeId)) continue;
      acc.visited.add(nodeId);
      const node = await this.fetchNode(nodeId, userId, ctx);
      if (!node) continue; // not visible / missing → omit
      acc.nodes.set(nodeId, node);
      if (expand) {
        await this.collectNeighbours(node, req, edgesTable, userId, ctx, acc, next);
      }
    }
    return next;
  }

  /** Merge a node's edges — explicit (the `edges` mount, primary) + the secondary
   *  generators (note/tag/reference) — record them, and queue unvisited peers. */
  private async collectNeighbours(
    node: GraphNode,
    req: GraphRequestDto,
    edgesTable: string,
    userId: string,
    ctx: Ctx,
    acc: GraphAcc,
    next: string[],
  ): Promise<void> {
    const explicit = await this.fetchEdges(node.id, req.edgesDbId, edgesTable, userId, ctx);
    const derived = generatedEdges(node, req.generators);
    for (const edge of [...explicit, ...derived]) {
      acc.edges.set(edge.id, edge);
      const other = edge.from === node.id ? edge.to : edge.from;
      if (!acc.visited.has(other)) next.push(other);
    }
  }

  private async fetchNode(nodeId: string, userId: string, ctx: Ctx): Promise<GraphNode | null> {
    let parsed: { dbId: string; resource: string; pk: string };
    try {
      parsed = parseNodeId(nodeId);
    } catch {
      return null; // malformed id → skip rather than fail the whole graph
    }
    const dto = new ExecuteQueryDto();
    dto.op = 'list';
    dto.filter = { id: parsed.pk };
    dto.limit = 1;
    try {
      const res = (await this.query.executeQuery(
        parsed.dbId,
        parsed.resource,
        userId,
        dto,
        ctx,
      )) as QueryRows;
      const row = res.rows?.[0];
      if (!row) return null;
      return { id: nodeId, mount: parsed.dbId, resource: parsed.resource, pk: parsed.pk, data: row };
    } catch (error) {
      this.logger.debug(`node ${nodeId} unreadable: ${(error as Error).message}`);
      return null;
    }
  }

  private async fetchEdges(
    nodeId: string,
    edgesDbId: string,
    edgesTable: string,
    userId: string,
    ctx: Ctx,
  ): Promise<EdgeRecord[]> {
    const dto = new ExecuteQueryDto();
    dto.op = 'list';
    dto.filter = { $or: [{ from: nodeId }, { to: nodeId }] };
    dto.limit = GraphService.EDGE_FANOUT;
    try {
      const res = (await this.query.executeQuery(
        edgesDbId,
        edgesTable,
        userId,
        dto,
        ctx,
      )) as QueryRows;
      return (res.rows ?? [])
        .map(toEdgeRecord)
        .filter((edge): edge is EdgeRecord => edge !== null);
    } catch (error) {
      this.logger.debug(`edges for ${nodeId} unreadable: ${(error as Error).message}`);
      return [];
    }
  }

  /** Keep only well-formed `{ dbId, table }` refs (the DTO array is loosely typed). */
  private validResources(resources: ResourceRef[]): ResourceRef[] {
    return (Array.isArray(resources) ? resources : []).filter(
      (r): r is ResourceRef =>
        !!r && typeof r.dbId === 'string' && typeof r.table === 'string',
    );
  }

  /** List up to `limit` rows of one resource as nodes (unreadable resource → []). */
  private async listNodes(
    dbId: string,
    table: string,
    limit: number,
    userId: string,
    ctx: Ctx,
  ): Promise<GraphNode[]> {
    const dto = new ExecuteQueryDto();
    dto.op = 'list';
    dto.limit = limit;
    try {
      const res = (await this.query.executeQuery(dbId, table, userId, dto, ctx)) as QueryRows;
      return (res.rows ?? [])
        .map((row) => this.rowToNode(dbId, table, row))
        .filter((node): node is GraphNode => node !== null);
    } catch (error) {
      this.logger.debug(`overview list ${dbId}:${table} failed: ${(error as Error).message}`);
      return [];
    }
  }

  /** A listed row → a node, keyed by its `id` column (the node PK convention). */
  private rowToNode(dbId: string, resource: string, row: Record<string, unknown>): GraphNode | null {
    const rawPk = row.id;
    if (typeof rawPk !== 'string' && typeof rawPk !== 'number') return null;
    const pk = String(rawPk);
    return { id: formatNodeId(dbId, resource, pk), mount: dbId, resource, pk, data: row };
  }

  /** Every edge in the `edges` mount (bounded), for the global overview. */
  private async listAllEdges(
    edgesDbId: string,
    edgesTable: string,
    userId: string,
    ctx: Ctx,
  ): Promise<EdgeRecord[]> {
    const dto = new ExecuteQueryDto();
    dto.op = 'list';
    dto.limit = GraphService.EDGE_FANOUT;
    try {
      const res = (await this.query.executeQuery(
        edgesDbId,
        edgesTable,
        userId,
        dto,
        ctx,
      )) as QueryRows;
      return (res.rows ?? [])
        .map(toEdgeRecord)
        .filter((edge): edge is EdgeRecord => edge !== null);
    } catch (error) {
      this.logger.debug(`overview edges ${edgesDbId}:${edgesTable} failed: ${(error as Error).message}`);
      return [];
    }
  }
}
