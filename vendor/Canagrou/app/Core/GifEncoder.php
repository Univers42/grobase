<?php

declare(strict_types=1);

namespace App\Core;

/**
 * Animated GIF Encoder
 * Creates animated GIFs from multiple GD image frames.
 * Produces GIF89a format with proper disposal and looping.
 */
class GifEncoder
{
    private string $gif = '';
    private int $delay;
    private int $loops;
    private bool $firstFrame = true;
    private ?string $globalColorTable = null;
    private int $width;
    private int $height;

    /**
     * @param int $delay  Frame delay in hundredths of a second (e.g., 25 = 0.25s)
     * @param int $loops  Number of loops (0 = infinite)
     */
    public function __construct(int $delay = 25, int $loops = 0)
    {
        $this->delay = $delay;
        $this->loops = $loops;
    }

    /**
     * Add a GD image as a frame. All frames must be same dimensions.
     */
    public function addFrame(\GdImage $image): void
    {
        // Capture frame as GIF binary
        ob_start();
        imagegif($image);
        $frameData = ob_get_clean();

        if ($this->firstFrame) {
            $this->width = imagesx($image);
            $this->height = imagesy($image);
            $this->writeHeader($frameData);
            $this->firstFrame = false;
        }

        $this->writeFrame($frameData);
    }

    /**
     * Finalize and return the animated GIF binary.
     */
    public function encode(): string
    {
        // GIF trailer
        $this->gif .= "\x3B";
        return $this->gif;
    }

    /**
     * Write the GIF89a header + global color table + Netscape looping extension.
     */
    private function writeHeader(string $frameData): void
    {
        // GIF89a signature
        $this->gif = "GIF89a";

        // Logical Screen Descriptor (7 bytes from offset 6)
        $this->gif .= substr($frameData, 6, 7);

        // Global Color Table
        $packed = ord($frameData[10]);
        $hasGCT = ($packed & 0x80) !== 0;
        $gctSize = $hasGCT ? 3 * (2 << ($packed & 0x07)) : 0;

        if ($hasGCT) {
            $this->globalColorTable = substr($frameData, 13, $gctSize);
            $this->gif .= $this->globalColorTable;
        }

        // Netscape Application Extension for looping
        $this->gif .= "\x21\xFF\x0B";
        $this->gif .= "NETSCAPE2.0";
        $this->gif .= "\x03\x01";
        $this->gif .= pack('v', $this->loops);
        $this->gif .= "\x00";
    }

    /**
     * Write a single frame with Graphic Control Extension.
     */
    private function writeFrame(string $frameData): void
    {
        // Parse the frame's GIF structure
        $packed = ord($frameData[10]);
        $hasGCT = ($packed & 0x80) !== 0;
        $gctSize = $hasGCT ? 3 * (2 << ($packed & 0x07)) : 0;

        // Graphic Control Extension
        $this->gif .= "\x21\xF9\x04";
        // Disposed to background, no user input, no transparent color
        $this->gif .= "\x04"; // disposal method = restore to background
        $this->gif .= pack('v', $this->delay); // delay time
        $this->gif .= "\x00"; // transparent color index (none)
        $this->gif .= "\x00"; // block terminator

        // Image descriptor + local color table + image data
        $headerSize = 13 + $gctSize; // GIF header + GCT
        $imageData = substr($frameData, $headerSize);

        // Remove GIF trailer (0x3B) if present at the end
        if ($imageData !== '' && $imageData[-1] === "\x3B") {
            $imageData = substr($imageData, 0, -1);
        }

        // Write the image descriptor block with local color table override
        if ($hasGCT) {
            // Replace image descriptor to include local color table
            $localColorTable = substr($frameData, 13, $gctSize);
            $descriptor = substr($imageData, 0, 10);

            // Set local color table flag in the packed byte
            $descPacked = ord($descriptor[9]);
            $descPacked |= 0x80; // has local color table
            $descPacked = ($descPacked & 0xF8) | ($packed & 0x07); // copy size bits

            $this->gif .= substr($descriptor, 0, 9);
            $this->gif .= chr($descPacked);
            $this->gif .= $localColorTable;
            $this->gif .= substr($imageData, 10);
        } else {
            $this->gif .= $imageData;
        }
    }

    /**
     * Convenience method: create an animated GIF from an array of GD images.
     *
     * @param \GdImage[] $frames  Array of GD images (same dimensions)
     * @param int        $delay   Frame delay in hundredths of a second
     * @param int        $loops   Number of loops (0 = infinite)
     * @return string    Binary GIF data
     */
    public static function createFromFrames(array $frames, int $delay = 25, int $loops = 0): string
    {
        $encoder = new self($delay, $loops);
        foreach ($frames as $frame) {
            $encoder->addFrame($frame);
        }
        return $encoder->encode();
    }
}
