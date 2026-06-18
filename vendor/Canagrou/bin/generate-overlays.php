<?php

/**
 * CAMAGRU — Overlay Generator
 * 
 * Generates PNG overlay images with alpha transparency using GD.
 * Run this once: php bin/generate-overlays.php
 */

declare(strict_types=1);

$outputDir = dirname(__DIR__) . '/public/assets/overlays/';
if (!is_dir($outputDir)) {
    mkdir($outputDir, 0775, true);
}

$size = 800; // Canvas size (square)

// ══════════════════════════════════════════════════════════════════
// Helper functions
// ══════════════════════════════════════════════════════════════════

function createTransparentCanvas(int $w, int $h): \GdImage
{
    $img = imagecreatetruecolor($w, $h);
    imagesavealpha($img, true);
    imagealphablending($img, false);
    $transparent = imagecolorallocatealpha($img, 0, 0, 0, 127);
    imagefill($img, 0, 0, $transparent);
    imagealphablending($img, true);
    return $img;
}

function saveOverlay(\GdImage $img, string $path): void
{
    imagesavealpha($img, true);
    imagepng($img, $path, 6);
    imagedestroy($img);
    echo "  ✓ Created: " . basename($path) . "\n";
}

// ══════════════════════════════════════════════════════════════════
// 1) FILM FRAME — Classic photo frame with sprocket holes
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

$black = imagecolorallocate($img, 20, 20, 20);
$dark  = imagecolorallocate($img, 35, 35, 35);
$strip = imagecolorallocatealpha($img, 0, 0, 0, 127); // transparent center

// Frame borders (top/bottom thick bars)
$borderH = 80;
imagefilledrectangle($img, 0, 0, $size - 1, $borderH - 1, $black);
imagefilledrectangle($img, 0, $size - $borderH, $size - 1, $size - 1, $black);

// Left and right thin borders
$borderW = 12;
imagefilledrectangle($img, 0, $borderH, $borderW - 1, $size - $borderH - 1, $dark);
imagefilledrectangle($img, $size - $borderW, $borderH, $size - 1, $size - $borderH - 1, $dark);

// Sprocket holes
$holeW = 28;
$holeH = 20;
$holeGap = 52;
$holeColor = imagecolorallocate($img, 50, 50, 50);
for ($x = 30; $x < $size - 30; $x += $holeGap) {
    // Top row
    imagefilledrectangle($img, $x, 20, $x + $holeW, 20 + $holeH, $holeColor);
    imagefilledrectangle($img, $x + 4, 24, $x + $holeW - 4, 16 + $holeH, imagecolorallocatealpha($img, 0, 0, 0, 100));
    // Bottom row
    imagefilledrectangle($img, $x, $size - 42, $x + $holeW, $size - 42 + $holeH, $holeColor);
    imagefilledrectangle($img, $x + 4, $size - 38, $x + $holeW - 4, $size - 42 + $holeH - 4, imagecolorallocatealpha($img, 0, 0, 0, 100));
}

// Inner frame line
$frameColor = imagecolorallocate($img, 60, 60, 60);
imagerectangle($img, $borderW + 4, $borderH + 4, $size - $borderW - 5, $size - $borderH - 5, $frameColor);

saveOverlay($img, $outputDir . 'film-frame.png');

// ══════════════════════════════════════════════════════════════════
// 2) RETRO SUNBURST BORDER — Colorful corner accents
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

// Draw diagonal stripe border pattern
$colors = [
    imagecolorallocatealpha($img, 255, 107, 107, 40), // red
    imagecolorallocatealpha($img, 255, 159, 67, 40),  // orange
    imagecolorallocatealpha($img, 254, 202, 87, 40),  // yellow
    imagecolorallocatealpha($img, 29, 209, 161, 40),  // green
    imagecolorallocatealpha($img, 72, 219, 251, 40),  // cyan
    imagecolorallocatealpha($img, 99, 102, 241, 40),  // indigo
];

// Corner triangle patterns (top-left)
$border = 60;
for ($i = 0; $i < 6; $i++) {
    $offset = $i * 10;
    // Top border
    imagefilledrectangle($img, $offset, $offset, $size - $offset - 1, $offset + 8, $colors[$i]);
    // Bottom border
    imagefilledrectangle($img, $offset, $size - $offset - 9, $size - $offset - 1, $size - $offset - 1, $colors[$i]);
    // Left border
    imagefilledrectangle($img, $offset, $offset, $offset + 8, $size - $offset - 1, $colors[$i]);
    // Right border
    imagefilledrectangle($img, $size - $offset - 9, $offset, $size - $offset - 1, $size - $offset - 1, $colors[$i]);
}

// Rounded corner circles
$cornerRadius = 40;
$white = imagecolorallocatealpha($img, 255, 255, 255, 60);
imagefilledellipse($img, $cornerRadius, $cornerRadius, $cornerRadius * 2, $cornerRadius * 2, $white);
imagefilledellipse($img, $size - $cornerRadius, $cornerRadius, $cornerRadius * 2, $cornerRadius * 2, $white);
imagefilledellipse($img, $cornerRadius, $size - $cornerRadius, $cornerRadius * 2, $cornerRadius * 2, $white);
imagefilledellipse($img, $size - $cornerRadius, $size - $cornerRadius, $cornerRadius * 2, $cornerRadius * 2, $white);

saveOverlay($img, $outputDir . 'retro-border.png');

// ══════════════════════════════════════════════════════════════════
// 3) STARS AND SPARKLES — Decorative stars scattered around
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

// Draw various stars
function drawStar(\GdImage $img, int $cx, int $cy, int $outerR, int $innerR, int $points, int $color): void
{
    $coords = [];
    for ($i = 0; $i < $points * 2; $i++) {
        $angle = deg2rad(-90 + ($i * 360 / ($points * 2)));
        $r = ($i % 2 === 0) ? $outerR : $innerR;
        $coords[] = (int)($cx + $r * cos($angle));
        $coords[] = (int)($cy + $r * sin($angle));
    }
    imagefilledpolygon($img, $coords, $color);
}

// Sparkle positions and sizes
$sparkles = [
    ['x' => 80,  'y' => 80,  'r' => 35, 'ir' => 14, 'pts' => 4, 'alpha' => 30],
    ['x' => 700, 'y' => 60,  'r' => 45, 'ir' => 18, 'pts' => 5, 'alpha' => 20],
    ['x' => 720, 'y' => 720, 'r' => 40, 'ir' => 16, 'pts' => 4, 'alpha' => 25],
    ['x' => 60,  'y' => 700, 'r' => 30, 'ir' => 12, 'pts' => 6, 'alpha' => 30],
    ['x' => 400, 'y' => 40,  'r' => 25, 'ir' => 10, 'pts' => 4, 'alpha' => 35],
    ['x' => 40,  'y' => 400, 'r' => 28, 'ir' => 11, 'pts' => 5, 'alpha' => 32],
    ['x' => 760, 'y' => 400, 'r' => 32, 'ir' => 13, 'pts' => 4, 'alpha' => 28],
    ['x' => 400, 'y' => 760, 'r' => 22, 'ir' => 9,  'pts' => 4, 'alpha' => 35],
    ['x' => 200, 'y' => 35,  'r' => 18, 'ir' => 7,  'pts' => 4, 'alpha' => 40],
    ['x' => 600, 'y' => 756, 'r' => 20, 'ir' => 8,  'pts' => 5, 'alpha' => 38],
    ['x' => 150, 'y' => 750, 'r' => 24, 'ir' => 10, 'pts' => 4, 'alpha' => 34],
    ['x' => 750, 'y' => 200, 'r' => 26, 'ir' => 10, 'pts' => 6, 'alpha' => 30],
];

$starColors = [
    [255, 215, 0],   // gold
    [255, 255, 255], // white
    [173, 216, 230], // light blue
    [255, 182, 193], // pink
    [152, 251, 152], // pale green
];

foreach ($sparkles as $s) {
    $colorIdx = array_rand($starColors);
    $rgb = $starColors[$colorIdx];
    $color = imagecolorallocatealpha($img, $rgb[0], $rgb[1], $rgb[2], $s['alpha']);
    drawStar($img, $s['x'], $s['y'], $s['r'], $s['ir'], $s['pts'], $color);
    
    // Add tiny glow around large stars
    if ($s['r'] > 25) {
        $glow = imagecolorallocatealpha($img, $rgb[0], $rgb[1], $rgb[2], $s['alpha'] + 40);
        imagefilledellipse($img, $s['x'], $s['y'], $s['r'] * 3, $s['r'] * 3, $glow);
    }
}

saveOverlay($img, $outputDir . 'sparkles.png');

// ══════════════════════════════════════════════════════════════════
// 4) HEART VIGNETTE — Hearts around the edges with vignette
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

// Vignette (dark corners)
for ($r = $size; $r > $size * 0.45; $r -= 2) {
    $alpha = (int)(127 - (($r - $size * 0.45) / ($size * 0.55)) * 70);
    $alpha = max(57, min(127, $alpha));
    $color = imagecolorallocatealpha($img, 0, 0, 0, $alpha);
    imagefilledellipse($img, (int)($size / 2), (int)($size / 2), (int)($r * 2), (int)($r * 2), $color);
}

// Draw hearts at edges
function drawHeart(\GdImage $img, int $cx, int $cy, int $sz, int $color): void
{
    // Simple heart using two circles + triangle
    $r = (int)($sz * 0.3);
    imagefilledellipse($img, $cx - $r, $cy - (int)($r * 0.3), $r * 2, $r * 2, $color);
    imagefilledellipse($img, $cx + $r, $cy - (int)($r * 0.3), $r * 2, $r * 2, $color);
    // Triangle bottom
    $points = [
        $cx - $sz + (int)($r * 0.3), $cy,
        $cx + $sz - (int)($r * 0.3), $cy,
        $cx, $cy + (int)($sz * 1.2),
    ];
    imagefilledpolygon($img, $points, $color);
}

$heartPositions = [
    ['x' => 60,  'y' => 60,  's' => 28],
    ['x' => 400, 'y' => 30,  's' => 22],
    ['x' => 740, 'y' => 55,  's' => 26],
    ['x' => 30,  'y' => 400, 's' => 20],
    ['x' => 770, 'y' => 400, 's' => 24],
    ['x' => 70,  'y' => 740, 's' => 25],
    ['x' => 400, 'y' => 770, 's' => 21],
    ['x' => 730, 'y' => 730, 's' => 27],
    ['x' => 200, 'y' => 25,  's' => 16],
    ['x' => 600, 'y' => 30,  's' => 18],
    ['x' => 25,  'y' => 600, 's' => 17],
    ['x' => 775, 'y' => 200, 's' => 19],
];

foreach ($heartPositions as $h) {
    $pinkAlpha = imagecolorallocatealpha($img, 255, 50, 80, rand(20, 50));
    drawHeart($img, $h['x'], $h['y'], $h['s'], $pinkAlpha);
}

saveOverlay($img, $outputDir . 'heart-vignette.png');

// ══════════════════════════════════════════════════════════════════
// 5) PIXEL ART BORDER — Retro pixelated frame
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

$pixelSize = 20;
$borderPixels = 3; // 3 pixels thick

$pixelColors = [
    imagecolorallocatealpha($img, 99, 102, 241, 30),  // indigo
    imagecolorallocatealpha($img, 139, 92, 246, 30),   // purple
    imagecolorallocatealpha($img, 236, 72, 153, 30),   // pink
    imagecolorallocatealpha($img, 59, 130, 246, 30),   // blue
    imagecolorallocatealpha($img, 16, 185, 129, 30),   // emerald
];

$gridCols = (int)($size / $pixelSize);

for ($row = 0; $row < $gridCols; $row++) {
    for ($col = 0; $col < $gridCols; $col++) {
        // Only draw in border area
        if ($row >= $borderPixels && $row < $gridCols - $borderPixels &&
            $col >= $borderPixels && $col < $gridCols - $borderPixels) {
            continue;
        }

        // Checkerboard-ish pattern with random colors
        if (($row + $col) % 2 === 0 || rand(0, 3) === 0) {
            $color = $pixelColors[array_rand($pixelColors)];
            imagefilledrectangle(
                $img,
                $col * $pixelSize, $row * $pixelSize,
                ($col + 1) * $pixelSize - 1, ($row + 1) * $pixelSize - 1,
                $color
            );
        }
    }
}

// Inner edge highlight
$highlight = imagecolorallocatealpha($img, 255, 255, 255, 100);
$innerX = $borderPixels * $pixelSize;
$innerY = $borderPixels * $pixelSize;
$innerW = $size - $borderPixels * $pixelSize - 1;
$innerH = $size - $borderPixels * $pixelSize - 1;
imagerectangle($img, $innerX, $innerY, $innerW, $innerH, $highlight);

saveOverlay($img, $outputDir . 'pixel-border.png');

// ══════════════════════════════════════════════════════════════════
// 6) NEON GLOW — Glowing neon rectangle frame
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

$padding = 50;

// Glow layers (outer to inner, fading)
for ($i = 20; $i >= 0; $i--) {
    $alpha = (int)(127 - (20 - $i) * 4);
    $alpha = max(40, $alpha);
    $neonColor = imagecolorallocatealpha($img, 99, 102, 241, $alpha);
    $offset = $padding + $i * 2;
    imagerectangle($img, $offset, $offset, $size - $offset - 1, $size - $offset - 1, $neonColor);
}

// Bright core line
$core = imagecolorallocatealpha($img, 180, 180, 255, 10);
imagerectangle($img, $padding, $padding, $size - $padding - 1, $size - $padding - 1, $core);
imagerectangle($img, $padding + 1, $padding + 1, $size - $padding - 2, $size - $padding - 2, $core);

// Corner decorations (circles)
$cornerGlow = imagecolorallocatealpha($img, 139, 92, 246, 30);
$cr = 20;
imagefilledellipse($img, $padding, $padding, $cr * 2, $cr * 2, $cornerGlow);
imagefilledellipse($img, $size - $padding, $padding, $cr * 2, $cr * 2, $cornerGlow);
imagefilledellipse($img, $padding, $size - $padding, $cr * 2, $cr * 2, $cornerGlow);
imagefilledellipse($img, $size - $padding, $size - $padding, $cr * 2, $cr * 2, $cornerGlow);

saveOverlay($img, $outputDir . 'neon-glow.png');

// ══════════════════════════════════════════════════════════════════
// 7) HALFTONE DOTS — Comic book style halftone edge effect
// ══════════════════════════════════════════════════════════════════

$img = createTransparentCanvas($size, $size);

$dotSpacing = 30;
$maxDotRadius = 12;
$fadeStart = 120; // Distance from edge where dots start fading

for ($y = 0; $y < $size; $y += $dotSpacing) {
    for ($x = 0; $x < $size; $x += $dotSpacing) {
        // Distance from nearest edge
        $distFromEdge = min($x, $y, $size - $x, $size - $y);

        if ($distFromEdge < $fadeStart) {
            // Dot size inversely proportional to distance from edge
            $factor = 1.0 - ($distFromEdge / $fadeStart);
            $dotR = (int)($maxDotRadius * $factor);

            if ($dotR > 1) {
                $alpha = (int)(20 + (1 - $factor) * 60);
                $dotColor = imagecolorallocatealpha($img, 15, 15, 15, $alpha);
                imagefilledellipse($img, $x, $y, $dotR * 2, $dotR * 2, $dotColor);
            }
        }
    }
}

saveOverlay($img, $outputDir . 'halftone.png');

echo "\n✅ All overlays generated in: {$outputDir}\n";
