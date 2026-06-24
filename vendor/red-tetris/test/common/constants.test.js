const {
  BOARD_WIDTH,
  BOARD_HEIGHT,
  PIECES,
  PIECE_NAMES,
  COLORS,
  GAME_MODES,
  SCORES,
  TICK_SPEED_MS,
} = require('../../src/common/constants');

describe('constants', () => {
  it('should define board dimensions', () => {
    expect(BOARD_WIDTH).toBe(10);
    expect(BOARD_HEIGHT).toBe(20);
  });

  it('should define tick speed', () => {
    expect(typeof TICK_SPEED_MS).toBe('number');
    expect(TICK_SPEED_MS).toBeGreaterThan(0);
  });

  it('should define all 7 tetrimino types', () => {
    expect(PIECE_NAMES.length).toBe(7);
    expect(PIECE_NAMES).toContain('I');
    expect(PIECE_NAMES).toContain('O');
    expect(PIECE_NAMES).toContain('T');
    expect(PIECE_NAMES).toContain('S');
    expect(PIECE_NAMES).toContain('Z');
    expect(PIECE_NAMES).toContain('J');
    expect(PIECE_NAMES).toContain('L');
  });

  it('should have 4 rotation states for each piece', () => {
    PIECE_NAMES.forEach(name => {
      expect(PIECES[name].rotations.length).toBe(4);
    });
  });

  it('should have unique colors for each piece', () => {
    const colors = PIECE_NAMES.map(name => PIECES[name].color);
    const unique = new Set(colors);
    expect(unique.size).toBe(7);
  });

  it('each rotation should have 4 cells', () => {
    PIECE_NAMES.forEach(name => {
      PIECES[name].rotations.forEach(rotation => {
        expect(rotation.length).toBe(4);
      });
    });
  });

  it('should define color mappings', () => {
    expect(COLORS[0]).toBe('transparent');
    expect(COLORS[8]).toBeDefined(); // Penalty
    expect(COLORS[9]).toBeDefined(); // Ghost
    for (let i = 1; i <= 7; i++) {
      expect(COLORS[i]).toBeDefined();
    }
  });

  it('should define game modes', () => {
    expect(GAME_MODES.CLASSIC).toBe('classic');
    expect(GAME_MODES.INVISIBLE).toBe('invisible');
    expect(GAME_MODES.GRAVITY).toBe('gravity');
  });

  it('should define scoring values', () => {
    expect(SCORES.SINGLE).toBeGreaterThan(0);
    expect(SCORES.DOUBLE).toBeGreaterThan(SCORES.SINGLE);
    expect(SCORES.TRIPLE).toBeGreaterThan(SCORES.DOUBLE);
    expect(SCORES.TETRIS).toBeGreaterThan(SCORES.TRIPLE);
    expect(SCORES.SOFT_DROP).toBeGreaterThan(0);
    expect(SCORES.HARD_DROP).toBeGreaterThan(SCORES.SOFT_DROP);
  });
});
