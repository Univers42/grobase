/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   mysql-schema.engine.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/01 14:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/01 01:40:54 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import mysql, { type Connection, type RowDataPacket } from 'mysql2/promise';
import { ColumnDefinition } from '../schemas/dto/schema.dto';

const TABLE_REGEX = /^[a-zA-Z_]\w{0,63}$/;
const COLUMN_REGEX = /^[a-zA-Z_]\w{0,63}$/;
const SAFE_DEFAULT_REGEX = /^(CURRENT_TIMESTAMP|NULL|true|false|-?\d+(\.\d+)?|'[^']{0,200}')$/i;

const TYPE_MAP: Record<string, string> = {
  text: 'TEXT',
  varchar: 'VARCHAR(255)',
  string: 'VARCHAR(255)',
  char: 'CHAR(255)',
  integer: 'INT',
  int: 'INT',
  bigint: 'BIGINT',
  smallint: 'SMALLINT',
  number: 'DOUBLE',
  numeric: 'DECIMAL(18,4)',
  decimal: 'DECIMAL(18,4)',
  real: 'DOUBLE',
  boolean: 'BOOLEAN',
  bool: 'BOOLEAN',
  date: 'DATE',
  timestamp: 'TIMESTAMP',
  timestamptz: 'TIMESTAMP',
  uuid: 'CHAR(36)',
  json: 'JSON',
  jsonb: 'JSON',
  object: 'JSON',
  array: 'JSON',
};

@Injectable()
export class MysqlSchemaEngine {
  private readonly logger = new Logger(MysqlSchemaEngine.name);

  async createTable(
    connectionString: string,
    tableName: string,
    columns: ColumnDefinition[],
  ): Promise<{ created: boolean; ddl: string }> {
    this.validateIdentifier(tableName, 'table');

    const columnDefinitions = [
      '`id` CHAR(36) PRIMARY KEY',
      '`owner_id` CHAR(36) NOT NULL',
      '`created_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP',
      '`updated_at` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP',
      ...columns.map((column) => this.columnDefinition(column)),
    ];
    const ddl = `CREATE TABLE IF NOT EXISTS \`${tableName}\` (\n  ${columnDefinitions.join(',\n  ')}\n) ENGINE=InnoDB`;

    const connection = await mysql.createConnection(connectionString);
    try {
      await connection.execute(ddl);
      await this.ensureOwnerIndex(connection, tableName);
      this.logger.log(`MySQL table created/updated: ${tableName}`);
      return { created: true, ddl };
    } finally {
      await connection.end().catch(() => undefined);
    }
  }

  async dropTable(connectionString: string, tableName: string): Promise<{ dropped: boolean }> {
    this.validateIdentifier(tableName, 'table');
    const connection = await mysql.createConnection(connectionString);
    try {
      await connection.execute(`DROP TABLE IF EXISTS \`${tableName}\``);
      this.logger.warn(`MySQL table dropped: ${tableName}`);
      return { dropped: true };
    } finally {
      await connection.end().catch(() => undefined);
    }
  }

  async listTables(connectionString: string): Promise<string[]> {
    const connection = await mysql.createConnection(connectionString);
    try {
      const [rows] = await connection.query<RowDataPacket[]>(
        `SELECT table_name AS name
           FROM information_schema.tables
          WHERE table_schema = DATABASE()
            AND table_type = 'BASE TABLE'
          ORDER BY table_name`,
      );
      return rows.map((row) => String(row['name'] ?? ''));
    } finally {
      await connection.end().catch(() => undefined);
    }
  }

  private columnDefinition(column: ColumnDefinition): string {
    this.validateIdentifier(column.name, 'column');
    const mappedType = TYPE_MAP[column.type.toLowerCase()];
    if (!mappedType) {
      throw new BadRequestException(`Unsupported type for MySQL: ${column.type}`);
    }

    let definition = `\`${column.name}\` ${mappedType}`;
    if (!column.nullable) definition += ' NOT NULL';
    if (column.unique) definition += ' UNIQUE';
    if (column.default_value) definition += ` DEFAULT ${this.safeDefault(column.default_value)}`;
    return definition;
  }

  private validateIdentifier(value: string, kind: string): void {
    const regex = kind === 'table' ? TABLE_REGEX : COLUMN_REGEX;
    if (!regex.test(value)) {
      throw new BadRequestException(`Invalid MySQL ${kind} name: ${value}`);
    }
  }

  private safeDefault(value: string): string {
    const trimmed = value.trim();
    if (!SAFE_DEFAULT_REGEX.test(trimmed)) {
      throw new BadRequestException(`Unsafe MySQL default expression: ${value}`);
    }
    return trimmed;
  }

  private async ensureOwnerIndex(connection: Connection, tableName: string): Promise<void> {
    const indexName = `idx_${tableName}_owner_created`;
    await connection
      .execute(`CREATE INDEX \`${indexName}\` ON \`${tableName}\` (\`owner_id\`, \`created_at\`)`)
      .catch((error: { errno?: number }) => {
        if (error.errno !== 1061) throw error;
      });
  }
}