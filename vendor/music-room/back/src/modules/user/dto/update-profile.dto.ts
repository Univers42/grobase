import { IsString, IsOptional, IsNumber, Min, Max } from 'class-validator';
import { ApiPropertyOptional } from '@nestjs/swagger';

export class UpdatePublicInfoDto {
  @ApiPropertyOptional({ example: 'John Doe' })
  @IsOptional()
  @IsString()
  displayName?: string;

  @ApiPropertyOptional({ example: 'https://example.com/avatar.png' })
  @IsOptional()
  @IsString()
  avatar?: string;

  @ApiPropertyOptional({ example: 'Music lover and DJ' })
  @IsOptional()
  @IsString()
  bio?: string;
}

export class UpdateFriendsInfoDto {
  @ApiPropertyOptional({ example: '+33612345678' })
  @IsOptional()
  @IsString()
  phone?: string;

  @ApiPropertyOptional({ example: 'Paris' })
  @IsOptional()
  @IsString()
  city?: string;

  @ApiPropertyOptional({ example: 25 })
  @IsOptional()
  @IsNumber()
  @Min(1)
  @Max(150)
  age?: number;
}

export class UpdatePrivateInfoDto {
  @ApiPropertyOptional({ example: true })
  @IsOptional()
  emailNotifications?: boolean;

  @ApiPropertyOptional({ example: 'Some notes' })
  @IsOptional()
  @IsString()
  personalNotes?: string;
}

export class UpdateMusicPreferencesDto {
  @ApiPropertyOptional({ example: ['rock', 'jazz'] })
  @IsOptional()
  @IsString({ each: true })
  favoriteGenres?: string[];

  @ApiPropertyOptional({ example: ['Daft Punk'] })
  @IsOptional()
  @IsString({ each: true })
  favoriteArtists?: string[];

  @ApiPropertyOptional({ example: ['chill', 'energetic'] })
  @IsOptional()
  @IsString({ each: true })
  preferredMoods?: string[];
}
