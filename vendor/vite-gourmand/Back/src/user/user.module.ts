/**
 * User Module
 * Provides user management functionality
 */
import { Module } from '@nestjs/common';
import { UserController } from './user.controller';
import { UserService } from './user.service';
import { AddressService } from './address.service';
import { SessionService } from './session.service';

@Module({
  controllers: [UserController],
  providers: [UserService, AddressService, SessionService],
  exports: [UserService],
})
export class UserModule {}
