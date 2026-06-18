/**
 * Time Off Service - Facade delegating to Employee and Admin services
 */
import { Injectable } from '@nestjs/common';
import { EmployeeTimeOffService } from './employee-timeoff.service';
import { AdminTimeOffService } from './admin-timeoff.service';
import {
  CreateTimeOffRequestDto,
  UpdateTimeOffRequestDto,
  DecideTimeOffRequestDto,
} from './dto/timeoff.dto';

@Injectable()
export class TimeOffService {
  constructor(
    private readonly employeeService: EmployeeTimeOffService,
    private readonly adminService: AdminTimeOffService,
  ) {}

  // Employee operations
  createRequest(dto: CreateTimeOffRequestDto, userId: number) {
    return this.employeeService.create(dto, userId);
  }
  getMyRequests(userId: number) {
    return this.employeeService.getMyRequests(userId);
  }
  updateRequest(id: number, dto: UpdateTimeOffRequestDto, userId: number) {
    return this.employeeService.update(id, dto, userId);
  }
  cancelRequest(id: number, userId: number) {
    return this.employeeService.cancel(id, userId);
  }

  // Admin operations
  findAll(options: { status?: string; userId?: number }) {
    return this.adminService.findAll(options);
  }
  getPendingRequests() {
    return this.adminService.getPending();
  }
  findById(id: number) {
    return this.adminService.findById(id);
  }
  decideRequest(id: number, dto: DecideTimeOffRequestDto, deciderId: number) {
    return this.adminService.decide(id, dto, deciderId);
  }
  deleteRequest(id: number) {
    return this.adminService.delete(id);
  }
  getSchedule(startDate: Date, endDate: Date) {
    return this.adminService.getSchedule(startDate, endDate);
  }
}
