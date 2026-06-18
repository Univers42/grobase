import {
  Controller,
  Post,
  Get,
  Body,
  Param,
  HttpCode,
  HttpStatus,
} from '@nestjs/common';
import { ApiTags, ApiOperation, ApiBearerAuth } from '@nestjs/swagger';
import { IoTService } from './iot.service';
import { CurrentUser } from '../../common/decorators/current-user.decorator';
import { IoTPlaybackCommandDto, IoTPublishStatusDto, IoTPairDeviceDto } from './dto';

@ApiTags('iot')
@ApiBearerAuth()
@Controller('iot')
export class IoTController {
  constructor(private readonly iotService: IoTService) {}

  @Get('status')
  @ApiOperation({ summary: 'Check IoT/MQTT connection status' })
  getStatus() {
    return {
      mqtt: this.iotService.isConnected(),
      message: this.iotService.isConnected()
        ? 'MQTT broker connected'
        : 'MQTT broker not connected — IoT features unavailable',
    };
  }

  @Post('playback/command')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Send playback command to user IoT devices' })
  sendPlaybackCommand(
    @CurrentUser() user: any,
    @Body() dto: IoTPlaybackCommandDto,
  ) {
    this.iotService.sendDeviceCommand(user._id.toString(), {
      action: dto.command,
      payload: dto.value !== undefined ? { value: dto.value } : undefined,
    });
    return { sent: true, command: dto.command };
  }

  @Post('playback/status')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Publish playback status to user IoT devices' })
  publishPlaybackStatus(
    @CurrentUser() user: any,
    @Body() dto: IoTPublishStatusDto,
  ) {
    this.iotService.publishPlaybackStatus(user._id.toString(), {
      trackId: dto.trackId,
      title: dto.title,
      artist: dto.artist,
      isPlaying: true,
      position: dto.position || 0,
      duration: dto.duration || 0,
    });
    return { published: true };
  }

  @Post('device/pair')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Initiate IoT device pairing via MQTT' })
  pairDevice(
    @CurrentUser() user: any,
    @Body() dto: IoTPairDeviceDto,
  ) {
    this.iotService.sendDeviceCommand(user._id.toString(), {
      action: 'pair',
      payload: {
        deviceId: dto.deviceId,
        deviceName: dto.deviceName,
        deviceType: dto.deviceType,
      },
    });
    return { pairing: true, deviceId: dto.deviceId };
  }

  @Post('event/:eventId/broadcast')
  @HttpCode(HttpStatus.OK)
  @ApiOperation({ summary: 'Broadcast now-playing for a live event to IoT displays' })
  broadcastEventTrack(
    @Param('eventId') eventId: string,
    @Body() dto: IoTPublishStatusDto,
  ) {
    this.iotService.broadcastEventNowPlaying(eventId, {
      trackId: dto.trackId,
      title: dto.title,
      artist: dto.artist,
    });
    return { broadcast: true, eventId };
  }
}
