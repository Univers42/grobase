import { Controller, Get, Query, Param, ParseIntPipe } from '@nestjs/common';
import { ApiTags, ApiOperation, ApiResponse, ApiBearerAuth, ApiQuery } from '@nestjs/swagger';
import { MusicService } from './music.service';

@ApiTags('music')
@ApiBearerAuth()
@Controller('music')
export class MusicController {
  constructor(private readonly musicService: MusicService) {}

  @Get('search')
  @ApiOperation({ summary: 'Search for tracks on Deezer' })
  @ApiQuery({ name: 'q', description: 'Search query', required: true })
  @ApiQuery({ name: 'limit', description: 'Max results', required: false })
  @ApiQuery({ name: 'index', description: 'Offset for pagination', required: false })
  @ApiResponse({ status: 200, description: 'Returns matching tracks' })
  async searchTracks(
    @Query('q') query: string,
    @Query('limit') limit?: number,
    @Query('index') index?: number,
  ) {
    return this.musicService.searchTracks(query, limit || 25, index || 0);
  }

  @Get('search/artists')
  @ApiOperation({ summary: 'Search for artists on Deezer' })
  @ApiQuery({ name: 'q', description: 'Search query', required: true })
  @ApiQuery({ name: 'limit', description: 'Max results', required: false })
  @ApiResponse({ status: 200, description: 'Returns matching artists' })
  async searchArtists(
    @Query('q') query: string,
    @Query('limit') limit?: number,
  ) {
    return this.musicService.searchArtists(query, limit || 10);
  }

  @Get('track/:id')
  @ApiOperation({ summary: 'Get track details by Deezer ID' })
  @ApiResponse({ status: 200, description: 'Returns track details' })
  async getTrack(@Param('id', ParseIntPipe) id: number) {
    return this.musicService.getTrack(id);
  }

  @Get('artist/:id')
  @ApiOperation({ summary: 'Get artist details by Deezer ID' })
  @ApiResponse({ status: 200, description: 'Returns artist details' })
  async getArtist(@Param('id', ParseIntPipe) id: number) {
    return this.musicService.getArtist(id);
  }

  @Get('artist/:id/top')
  @ApiOperation({ summary: 'Get artist top tracks' })
  @ApiQuery({ name: 'limit', description: 'Max results', required: false })
  @ApiResponse({ status: 200, description: 'Returns top tracks' })
  async getArtistTopTracks(
    @Param('id', ParseIntPipe) id: number,
    @Query('limit') limit?: number,
  ) {
    return this.musicService.getArtistTopTracks(id, limit || 10);
  }

  @Get('album/:id')
  @ApiOperation({ summary: 'Get album details by Deezer ID' })
  @ApiResponse({ status: 200, description: 'Returns album details' })
  async getAlbum(@Param('id', ParseIntPipe) id: number) {
    return this.musicService.getAlbum(id);
  }
}
