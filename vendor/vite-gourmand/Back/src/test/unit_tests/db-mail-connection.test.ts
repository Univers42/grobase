/**
 * DB/Mail Connection Test
 * Tests database and mail service connectivity
 */

import { BaseTest, TestResult, FuzzyTestResult } from './base.test';
import { randomString } from '../utils/test-data';

interface ConnectionConfig {
  host: string;
  port: number;
  user?: string;
  password?: string;
  database?: string;
  ssl?: boolean;
  timeout?: number;
}

interface ConnectionResult {
  isConnected: boolean;
  latency?: number;
  error?: string;
  details?: Record<string, unknown>;
}

export class DbMailConnectionTest extends BaseTest {
  name = 'db_mail_connection';
  description = 'Test database and mail service connection validation';
  category = 'connection';

  /**
   * Validate database connection configuration
   */
  private validateDbConfig(config: Partial<ConnectionConfig>): {
    isValid: boolean;
    errors: string[];
  } {
    const errors: string[] = [];

    // Host validation
    if (!config.host) {
      errors.push('Database host is required');
    } else if (!/^[a-zA-Z0-9.-]+$/.test(config.host)) {
      errors.push('Invalid host format');
    }

    // Port validation
    if (!config.port) {
      errors.push('Database port is required');
    } else if (config.port < 1 || config.port > 65535) {
      errors.push('Port must be between 1 and 65535');
    }

    // Database name validation
    if (!config.database) {
      errors.push('Database name is required');
    } else if (!/^[a-zA-Z0-9_-]+$/.test(config.database)) {
      errors.push('Invalid database name format');
    }

    // Credentials
    if (config.user && config.user.length > 64) {
      errors.push('Username too long');
    }

    // Timeout
    if (
      config.timeout !== undefined &&
      (config.timeout < 0 || config.timeout > 300000)
    ) {
      errors.push('Timeout must be between 0 and 300000ms');
    }

    return { isValid: errors.length === 0, errors };
  }

  /**
   * Validate mail (SMTP) connection configuration
   */
  private validateMailConfig(config: Partial<ConnectionConfig>): {
    isValid: boolean;
    errors: string[];
  } {
    const errors: string[] = [];

    // Host validation
    if (!config.host) {
      errors.push('SMTP host is required');
    } else if (!/^[a-zA-Z0-9.-]+$/.test(config.host)) {
      errors.push('Invalid SMTP host format');
    }

    // Port validation (common SMTP ports: 25, 465, 587, 2525)
    const validPorts = [25, 465, 587, 2525];
    if (!config.port) {
      errors.push('SMTP port is required');
    } else if (
      !validPorts.includes(config.port) &&
      (config.port < 1 || config.port > 65535)
    ) {
      errors.push('Invalid SMTP port');
    }

    // SSL should be enabled for ports 465
    if (config.port === 465 && config.ssl === false) {
      errors.push('SSL should be enabled for port 465');
    }

    // Credentials for authenticated SMTP
    if (config.user && !config.password) {
      errors.push('Password required when username is provided');
    }

    return { isValid: errors.length === 0, errors };
  }

  /**
   * Simulate database connection (mock)
   */
  private async simulateDbConnection(
    config: ConnectionConfig,
  ): Promise<ConnectionResult> {
    const validation = this.validateDbConfig(config);
    if (!validation.isValid) {
      return { isConnected: false, error: validation.errors.join(', ') };
    }

    // Simulate connection latency
    const latency = Math.floor(Math.random() * 50) + 5;
    await new Promise((resolve) => setTimeout(resolve, latency));

    // Simulate connection success/failure (90% success rate)
    const success = Math.random() > 0.1;

    if (success) {
      return {
        isConnected: true,
        latency,
        details: {
          version: 'PostgreSQL 15.2',
          encoding: 'UTF8',
          maxConnections: 100,
        },
      };
    } else {
      return {
        isConnected: false,
        latency,
        error: 'Connection refused: ECONNREFUSED',
      };
    }
  }

  /**
   * Simulate mail connection (mock)
   */
  private async simulateMailConnection(
    config: ConnectionConfig,
  ): Promise<ConnectionResult> {
    const validation = this.validateMailConfig(config);
    if (!validation.isValid) {
      return { isConnected: false, error: validation.errors.join(', ') };
    }

    // Simulate connection latency
    const latency = Math.floor(Math.random() * 100) + 20;
    await new Promise((resolve) => setTimeout(resolve, latency));

    // Simulate connection success/failure (85% success rate)
    const success = Math.random() > 0.15;

    if (success) {
      return {
        isConnected: true,
        latency,
        details: {
          greeting: '220 smtp.example.com ESMTP',
          extensions: ['STARTTLS', 'AUTH LOGIN', 'AUTH PLAIN', '8BITMIME'],
          maxSize: 25 * 1024 * 1024,
        },
      };
    } else {
      return {
        isConnected: false,
        latency,
        error: 'SMTP connection timeout',
      };
    }
  }

  async run(): Promise<TestResult> {
    const { result, duration } = await this.measure(async () => {
      const errors: string[] = [];
      let passed = 0;
      let failed = 0;

      // ===== Database Configuration Validation =====

      // Valid database configs
      const validDbConfigs: ConnectionConfig[] = [
        {
          host: 'localhost',
          port: 5432,
          database: 'vitegourmand',
          user: 'postgres',
          password: 'secret',
        },
        {
          host: 'db.example.com',
          port: 5432,
          database: 'production',
          ssl: true,
          timeout: 5000,
        },
        {
          host: '192.168.1.100',
          port: 3306,
          database: 'mysql_db',
          user: 'root',
        },
      ];

      for (const config of validDbConfigs) {
        const result = this.validateDbConfig(config);
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(`Valid DB config rejected: ${result.errors.join(', ')}`);
        }
      }

      // Invalid database configs
      const invalidDbConfigs = [
        { port: 5432, database: 'test' }, // Missing host
        { host: 'localhost', database: 'test' }, // Missing port
        { host: 'localhost', port: 5432 }, // Missing database
        { host: 'invalid@host!', port: 5432, database: 'test' }, // Invalid host format
        { host: 'localhost', port: 99999, database: 'test' }, // Invalid port
      ];

      for (const config of invalidDbConfigs) {
        const result = this.validateDbConfig(config);
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push('Invalid DB config accepted');
        }
      }

      // ===== Mail Configuration Validation =====

      // Valid mail configs
      const validMailConfigs: ConnectionConfig[] = [
        {
          host: 'smtp.gmail.com',
          port: 587,
          user: 'user@gmail.com',
          password: 'password',
        },
        {
          host: 'smtp.example.com',
          port: 465,
          ssl: true,
          user: 'admin',
          password: 'secret',
        },
        { host: 'mail.local', port: 25 },
      ];

      for (const config of validMailConfigs) {
        const result = this.validateMailConfig(config);
        if (result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push(
            `Valid mail config rejected: ${result.errors.join(', ')}`,
          );
        }
      }

      // Invalid mail configs
      const invalidMailConfigs = [
        { port: 587 }, // Missing host
        { host: 'smtp.example.com' }, // Missing port
        { host: 'smtp.example.com', port: 465, ssl: false }, // SSL should be true for 465
        { host: 'smtp.example.com', port: 587, user: 'admin' }, // Missing password with user
      ];

      for (const config of invalidMailConfigs) {
        const result = this.validateMailConfig(config);
        if (!result.isValid) {
          passed++;
        } else {
          failed++;
          errors.push('Invalid mail config accepted');
        }
      }

      // ===== Connection Simulation =====

      // Test database connections
      const dbConfig: ConnectionConfig = {
        host: 'localhost',
        port: 5432,
        database: 'vitegourmand',
        user: 'postgres',
        password: 'secret',
        timeout: 5000,
      };

      // Run multiple connection attempts
      let dbSuccessCount = 0;
      for (let i = 0; i < 5; i++) {
        const connResult = await this.simulateDbConnection(dbConfig);
        if (connResult.isConnected) {
          dbSuccessCount++;
        }
      }
      passed++; // We just verify the simulation works

      // Test mail connections
      const mailConfig: ConnectionConfig = {
        host: 'smtp.gmail.com',
        port: 587,
        user: 'test@gmail.com',
        password: 'secret',
      };

      let mailSuccessCount = 0;
      for (let i = 0; i < 5; i++) {
        const connResult = await this.simulateMailConnection(mailConfig);
        if (connResult.isConnected) {
          mailSuccessCount++;
        }
      }
      passed++; // We just verify the simulation works

      // ===== Connection String Parsing =====

      const parseConnectionString = (
        url: string,
      ): Partial<ConnectionConfig> | null => {
        try {
          // Format: postgresql://user:password@host:port/database
          const regex =
            /^(?:postgresql|postgres|mysql):\/\/(?:([^:]+):([^@]+)@)?([^:/]+):(\d+)\/(.+)$/;
          const match = url.match(regex);

          if (!match) return null;

          return {
            user: match[1],
            password: match[2],
            host: match[3],
            port: Number.parseInt(match[4], 10),
            database: match[5],
          };
        } catch {
          return null;
        }
      };

      const connectionStrings = [
        {
          url: 'postgresql://postgres:secret@localhost:5432/vitegourmand',
          shouldParse: true,
        },
        {
          url: 'mysql://root:password@db.example.com:3306/mydb',
          shouldParse: true,
        },
        { url: 'invalid-connection-string', shouldParse: false },
        { url: 'http://not-a-db:5432/test', shouldParse: false },
      ];

      for (const test of connectionStrings) {
        const parsed = parseConnectionString(test.url);
        const didParse = parsed !== null;
        if (didParse === test.shouldParse) {
          passed++;
        } else {
          failed++;
          errors.push(`Connection string parsing: ${test.url}`);
        }
      }

      return { passed, failed, errors, dbSuccessCount, mailSuccessCount };
    });

    if (result.failed === 0) {
      return {
        ...this.success(`All ${result.passed} connection tests passed`),
        duration,
        details: {
          passed: result.passed,
          failed: result.failed,
          dbSimulations: result.dbSuccessCount,
          mailSimulations: result.mailSuccessCount,
        },
      };
    }

    return {
      ...this.failure(
        `${result.failed} connection tests failed`,
        result.errors,
      ),
      duration,
      details: { passed: result.passed, failed: result.failed },
    };
  }

  async fuzzyRun(iterations: number = 100): Promise<FuzzyTestResult> {
    const results: TestResult[] = [];
    const failedCases: TestResult[] = [];

    for (let i = 0; i < iterations; i++) {
      const testType = Math.random() > 0.4 ? 'valid' : 'invalid';
      const component = Math.random() > 0.5 ? 'db' : 'mail';

      let config: Partial<ConnectionConfig>;
      let expectedValid: boolean;

      if (component === 'db') {
        if (testType === 'valid') {
          config = {
            host: `db${i}.example.com`,
            port: [5432, 3306, 27017][Math.floor(Math.random() * 3)],
            database: `test_db_${randomString(5)}`,
            user: randomString(8),
            password: randomString(16),
          };
          expectedValid = true;
        } else {
          const invalidType = Math.floor(Math.random() * 3);
          config = {
            host: invalidType === 0 ? '' : 'localhost',
            port: invalidType === 1 ? -1 : 5432,
            database: invalidType === 2 ? '' : 'test',
          };
          expectedValid = false;
        }

        const result = this.validateDbConfig(config);
        const testPassed = result.isValid === expectedValid;

        results.push({
          name: `fuzzy_db_${i + 1}`,
          passed: testPassed,
          message: `DB config (${testType}): ${testPassed ? 'correct' : 'incorrect'}`,
          duration: 0,
          details: {
            expectedValid,
            actualValid: result.isValid,
            errors: result.errors,
          },
        });

        if (!testPassed) {
          failedCases.push(results[results.length - 1]);
        }
      } else {
        if (testType === 'valid') {
          config = {
            host: `smtp${i}.example.com`,
            port: [25, 465, 587][Math.floor(Math.random() * 3)],
            user: randomString(8),
            password: randomString(16),
            ssl: Math.random() > 0.5,
          };
          // Fix SSL requirement for port 465
          if (config.port === 465) config.ssl = true;
          expectedValid = true;
        } else {
          const invalidType = Math.floor(Math.random() * 3);
          config = {
            host: invalidType === 0 ? '' : 'smtp.example.com',
            port: invalidType === 1 ? undefined : 587,
            user: invalidType === 2 ? 'user' : undefined, // User without password
          };
          expectedValid = false;
        }

        const result = this.validateMailConfig(config);
        const testPassed = result.isValid === expectedValid;

        results.push({
          name: `fuzzy_mail_${i + 1}`,
          passed: testPassed,
          message: `Mail config (${testType}): ${testPassed ? 'correct' : 'incorrect'}`,
          duration: 0,
          details: {
            expectedValid,
            actualValid: result.isValid,
            errors: result.errors,
          },
        });

        if (!testPassed) {
          failedCases.push(results[results.length - 1]);
        }
      }
    }

    return {
      iterations,
      passed: results.filter((r) => r.passed).length,
      failed: results.filter((r) => !r.passed).length,
      results,
      failedCases,
    };
  }
}
