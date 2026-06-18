/**
 * Test Runner Module
 */
import { Module } from '@nestjs/common';
import { TestRunnerService } from './test-runner.service';
import { TestRunnerController } from './test-runner.controller';

@Module({
  controllers: [TestRunnerController],
  providers: [TestRunnerService],
  exports: [TestRunnerService],
})
export class TestRunnerModule {}
