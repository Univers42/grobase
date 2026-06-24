import { IsString } from 'class-validator';
import { ApiProperty } from '@nestjs/swagger';

export class SocialAuthDto {
  @ApiProperty({ example: 'oauth-access-token-from-provider', description: 'OAuth access token from Google or Facebook' })
  @IsString()
  accessToken: string;
}
