/**
 * Test Runner Controller
 * API endpoints for running and fetching test results
 */
import {
  Controller,
  Get,
  Post,
  Body,
  HttpException,
  HttpStatus,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiOkResponse } from '@nestjs/swagger';
import {
  TestRunnerService,
  RunTestsResponse,
  LegacyTestSuite,
} from './test-runner.service';
import { Public } from '../../common';

interface RunTestsDto {
  testId?: string;
  verbose?: boolean;
}

@ApiTags('Tests')
@Controller('tests')
export class TestRunnerController {
  constructor(private readonly service: TestRunnerService) {}

  @Post('run')
  @Public()
  @ApiOperation({ summary: 'Run a specific test suite' })
  async runTests(@Body() dto: RunTestsDto): Promise<RunTestsResponse> {
    try {
      return await this.service.runTests(dto.testId || 'unit', dto.verbose);
    } catch (error) {
      throw new HttpException(
        {
          success: false,
          message:
            error instanceof Error ? error.message : 'Test execution failed',
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }

  @Post('run-all')
  @Public()
  @ApiOperation({ summary: 'Run all test suites' })
  async runAllTests(@Body() dto: RunTestsDto): Promise<RunTestsResponse> {
    try {
      return await this.service.runAllTests(dto.verbose);
    } catch (error) {
      throw new HttpException(
        {
          success: false,
          message:
            error instanceof Error ? error.message : 'Test execution failed',
        },
        HttpStatus.INTERNAL_SERVER_ERROR,
      );
    }
  }

  @Get('results')
  @Public()
  @ApiOperation({ summary: 'Get cached test results' })
  async getResults(): Promise<RunTestsResponse | null> {
    return this.service.getResults();
  }

  @Get('status')
  @Public()
  @ApiOperation({ summary: 'Get test execution status' })
  getStatus(): { running: boolean; currentTest: string | null } {
    return this.service.getStatus();
  }

  // Legacy endpoints for backward compatibility
  @Get('unit')
  @Public()
  @ApiOperation({ summary: 'Get unit test results (legacy)' })
  @ApiOkResponse({ description: 'Unit test results' })
  async getUnitResults(): Promise<LegacyTestSuite[]> {
    return this.service.getUnitTestResults();
  }

  @Get('e2e')
  @Public()
  @ApiOperation({ summary: 'Get e2e test results (legacy)' })
  @ApiOkResponse({ description: 'E2E test results' })
  async getE2eResults(): Promise<LegacyTestSuite[]> {
    return this.service.getE2eTestResults();
  }

  @Get('summary')
  @Public()
  @ApiOperation({ summary: 'Get all test results summary (legacy)' })
  @ApiOkResponse({ description: 'All test results' })
  async getSummary(): Promise<{
    unit: LegacyTestSuite[];
    e2e: LegacyTestSuite[];
  }> {
    return this.service.getSummary();
  }
}
