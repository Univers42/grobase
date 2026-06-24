<?php

declare(strict_types=1);

namespace App\Controllers;

use App\Core\Controller;
use App\Core\Session;
use App\Core\GifEncoder;
use App\Models\Post;

/**
 * EditorController — Webcam capture, image upload, overlay composition.
 */
class EditorController extends Controller
{
    private Post $post;
    private string $uploadsDir;
    private string $overlaysDir;

    public function __construct()
    {
        $this->post = new Post();
        $this->uploadsDir  = dirname(__DIR__, 2) . '/public/uploads/';
        $this->overlaysDir = dirname(__DIR__, 2) . '/public/assets/overlays/';

        // Ensure uploads directory exists and is writable
        if (!is_dir($this->uploadsDir)) {
            mkdir($this->uploadsDir, 0777, true);
        }
        if (!is_writable($this->uploadsDir)) {
            chmod($this->uploadsDir, 0777);
        }
    }

    /**
     * Show the editor page with webcam, overlays and user's previous images.
     */
    public function index(): void
    {
        $this->requireAuth();

        // List available overlay images
        $overlays = $this->getOverlays();

        // User's previous captures
        $myImages = $this->post->findByUser($this->userId());

        $this->render('editor/index', [
            '_title'   => 'Photo Editor — Camagru',
            'overlays' => $overlays,
            'myImages' => $myImages,
        ]);
    }

    /**
     * Capture a webcam snapshot: receive base64 image + overlay ID.
     * Compose server-side with GD and save.
     */
    public function capture(): void
    {
        $this->requireAuth();

        $imageData = $this->input('image');
        $overlayId = $this->input('overlay');

        if (empty($imageData) || empty($overlayId)) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Missing image data or overlay selection.'], 400);
            }
            Session::flash('error', 'Missing image data or overlay selection.');
            $this->redirect('/editor');
            return;
        }

        // Validate base64 image
        if (!preg_match('/^data:image\/(png|jpeg|webp);base64,/', $imageData, $matches)) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Invalid image format.'], 400);
            }
            Session::flash('error', 'Invalid image format.');
            $this->redirect('/editor');
            return;
        }

        // Decode base64
        $base64 = preg_replace('/^data:image\/\w+;base64,/', '', $imageData);
        $decoded = base64_decode($base64, true);
        if ($decoded === false || strlen($decoded) > 10 * 1024 * 1024) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Image data too large or corrupt.'], 400);
            }
            Session::flash('error', 'Image data too large or corrupt.');
            $this->redirect('/editor');
            return;
        }

        // Create GD image from decoded data
        $userImage = @imagecreatefromstring($decoded);
        if (!$userImage) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Could not process image.'], 400);
            }
            Session::flash('error', 'Could not process image.');
            $this->redirect('/editor');
            return;
        }

        // Compose with overlay
        $result = $this->composeImage($userImage, $overlayId);
        if (!$result) {
            imagedestroy($userImage);
            if ($this->wantsJson()) {
                $this->json(['error' => 'Failed to compose image.'], 500);
            }
            Session::flash('error', 'Failed to compose image.');
            $this->redirect('/editor');
            return;
        }

        imagedestroy($userImage);

        // Save to database
        $postId = $this->post->createPost($this->userId(), $result);

        if ($this->wantsJson()) {
            $this->json([
                'success' => true,
                'post_id' => $postId,
                'image'   => $result,
                'message' => 'Image captured and saved!',
            ]);
            return;
        }

        Session::flash('success', 'Image captured and saved!');
        $this->redirect('/editor');
    }

    /**
     * Upload an image file instead of webcam capture.
     */
    public function upload(): void
    {
        $this->requireAuth();

        $overlayId = $this->input('overlay');

        if (empty($overlayId)) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Please select an overlay first.'], 400);
            }
            Session::flash('error', 'Please select an overlay first.');
            $this->redirect('/editor');
            return;
        }

        // Validate uploaded file
        if (!isset($_FILES['image']) || $_FILES['image']['error'] !== UPLOAD_ERR_OK) {
            $errorMsg = $this->getUploadErrorMessage($_FILES['image']['error'] ?? UPLOAD_ERR_NO_FILE);
            if ($this->wantsJson()) {
                $this->json(['error' => $errorMsg], 400);
            }
            Session::flash('error', $errorMsg);
            $this->redirect('/editor');
            return;
        }

        $file = $_FILES['image'];

        // Validate MIME type
        $finfo = new \finfo(FILEINFO_MIME_TYPE);
        $mimeType = $finfo->file($file['tmp_name']);
        $allowedMimes = ['image/jpeg', 'image/png', 'image/webp'];

        if (!in_array($mimeType, $allowedMimes, true)) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Only JPEG, PNG and WebP images are allowed.'], 400);
            }
            Session::flash('error', 'Only JPEG, PNG and WebP images are allowed.');
            $this->redirect('/editor');
            return;
        }

        // Validate file size (max 5MB)
        if ($file['size'] > 5 * 1024 * 1024) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Image must be smaller than 5MB.'], 400);
            }
            Session::flash('error', 'Image must be smaller than 5MB.');
            $this->redirect('/editor');
            return;
        }

        // Create GD image from upload
        $userImage = match ($mimeType) {
            'image/jpeg' => @imagecreatefromjpeg($file['tmp_name']),
            'image/png'  => @imagecreatefrompng($file['tmp_name']),
            'image/webp' => @imagecreatefromwebp($file['tmp_name']),
            default      => false,
        };

        if (!$userImage) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Could not process uploaded image.'], 400);
            }
            Session::flash('error', 'Could not process uploaded image.');
            $this->redirect('/editor');
            return;
        }

        // Compose with overlay
        $result = $this->composeImage($userImage, $overlayId);
        if (!$result) {
            imagedestroy($userImage);
            if ($this->wantsJson()) {
                $this->json(['error' => 'Failed to compose image.'], 500);
            }
            Session::flash('error', 'Failed to compose image.');
            $this->redirect('/editor');
            return;
        }

        imagedestroy($userImage);

        // Save to database
        $postId = $this->post->createPost($this->userId(), $result);

        if ($this->wantsJson()) {
            $this->json([
                'success' => true,
                'post_id' => $postId,
                'image'   => $result,
                'message' => 'Image uploaded and composed!',
            ]);
            return;
        }

        Session::flash('success', 'Image uploaded and composed!');
        $this->redirect('/editor');
    }

    /**
     * Delete user's own image.
     */
    public function delete(array $params = []): void
    {
        $this->requireAuth();

        $postId = (int)($params['id'] ?? 0);

        if (!$this->post->deleteByUser($postId, $this->userId())) {
            if ($this->wantsJson()) {
                $this->json(['error' => 'Image not found or access denied.'], 403);
            }
            Session::flash('error', 'Image not found or access denied.');
            $this->redirect('/editor');
            return;
        }

        if ($this->wantsJson()) {
            $this->json(['success' => true, 'message' => 'Image deleted.']);
            return;
        }

        Session::flash('success', 'Image deleted.');
        $this->redirect('/editor');
    }

    /**
     * Return user's images as JSON (for AJAX refresh).
     */
    public function myImages(): void
    {
        $this->requireAuth();

        $images = $this->post->findByUser($this->userId());
        $this->json(['images' => $images]);
    }

    // ─── Private Helpers ───────────────────────────────────────────

    /**
     * Capture an animated GIF: receive array of base64 frames + overlay ID.
     * Composes each frame server-side with GD, then creates animated GIF.
     */
    public function captureGif(): void
    {
        $this->requireAuth();

        $framesData = $this->jsonBody()['frames'] ?? [];
        $overlayId  = $this->input('overlay');

        if (empty($framesData) || !is_array($framesData) || count($framesData) < 2) {
            $this->json(['error' => 'At least 2 frames are required for a GIF.'], 400);
            return;
        }

        if (count($framesData) > 10) {
            $this->json(['error' => 'Maximum 10 frames for a GIF.'], 400);
            return;
        }

        if (empty($overlayId)) {
            $this->json(['error' => 'Missing overlay selection.'], 400);
            return;
        }

        // Validate overlay
        $overlayPath = $this->overlaysDir . basename($overlayId) . '.png';
        if (!file_exists($overlayPath)) {
            $this->json(['error' => 'Invalid overlay.'], 400);
            return;
        }

        $overlay = @imagecreatefrompng($overlayPath);
        if (!$overlay) {
            $this->json(['error' => 'Failed to load overlay.'], 500);
            return;
        }

        $composedFrames = [];
        $overlayW = imagesx($overlay);
        $overlayH = imagesy($overlay);

        foreach ($framesData as $idx => $frameBase64) {
            // Validate base64
            if (!preg_match('/^data:image\/(png|jpeg|webp);base64,/', $frameBase64)) {
                imagedestroy($overlay);
                foreach ($composedFrames as $f) imagedestroy($f);
                $this->json(['error' => "Invalid image format on frame " . ($idx + 1) . "."], 400);
                return;
            }

            $base64 = preg_replace('/^data:image\/\w+;base64,/', '', $frameBase64);
            $decoded = base64_decode($base64, true);
            if ($decoded === false || strlen($decoded) > 10 * 1024 * 1024) {
                imagedestroy($overlay);
                foreach ($composedFrames as $f) imagedestroy($f);
                $this->json(['error' => 'Frame data too large or corrupt.'], 400);
                return;
            }

            $userImage = @imagecreatefromstring($decoded);
            if (!$userImage) {
                imagedestroy($overlay);
                foreach ($composedFrames as $f) imagedestroy($f);
                $this->json(['error' => 'Could not process frame ' . ($idx + 1) . '.'], 400);
                return;
            }

            $userW = imagesx($userImage);
            $userH = imagesy($userImage);

            // Create composed frame
            $canvas = imagecreatetruecolor($userW, $userH);
            imagealphablending($canvas, true);
            imagesavealpha($canvas, true);
            imagecopy($canvas, $userImage, 0, 0, 0, 0, $userW, $userH);
            imagecopyresampled($canvas, $overlay, 0, 0, 0, 0, $userW, $userH, $overlayW, $overlayH);

            // Convert to palette (required for GIF)
            imagetruecolortopalette($canvas, true, 256);

            $composedFrames[] = $canvas;
            imagedestroy($userImage);
        }

        imagedestroy($overlay);

        // Create animated GIF
        $gifData = GifEncoder::createFromFrames($composedFrames, 20, 0);

        // Cleanup frames
        foreach ($composedFrames as $f) imagedestroy($f);

        // Save GIF file
        $filename = sprintf('%d_%s.gif', $this->userId(), bin2hex(random_bytes(8)));
        $savePath = $this->uploadsDir . $filename;

        if (file_put_contents($savePath, $gifData) === false) {
            $this->json(['error' => 'Failed to save GIF.'], 500);
            return;
        }

        $relativePath = '/uploads/' . $filename;
        $postId = $this->post->createPost($this->userId(), $relativePath);

        $this->json([
            'success' => true,
            'post_id' => $postId,
            'image'   => $relativePath,
            'message' => 'Animated GIF created!',
        ]);
    }

    // ─── End Public Methods ─────────────────────────────────────────

    /**
     * Compose user image with selected overlay using GD.
     * Returns the relative path to the saved file, or null on failure.
     */
    private function composeImage(\GdImage $userImage, string $overlayId): ?string
    {
        // Validate overlay exists
        $overlayPath = $this->overlaysDir . basename($overlayId) . '.png';
        if (!file_exists($overlayPath)) {
            return null;
        }

        // Load overlay (must be PNG with alpha)
        $overlay = @imagecreatefrompng($overlayPath);
        if (!$overlay) {
            return null;
        }

        // Dimensions
        $userW = imagesx($userImage);
        $userH = imagesy($userImage);
        $overlayW = imagesx($overlay);
        $overlayH = imagesy($overlay);

        // Create output canvas at user image size
        $canvas = imagecreatetruecolor($userW, $userH);
        if (!$canvas) {
            imagedestroy($overlay);
            return null;
        }

        // Preserve alpha
        imagealphablending($canvas, true);
        imagesavealpha($canvas, true);

        // Copy user image onto canvas
        imagecopy($canvas, $userImage, 0, 0, 0, 0, $userW, $userH);

        // Resize overlay to fit canvas, preserving aspect ratio
        // Scale overlay to fill the canvas dimensions
        imagecopyresampled(
            $canvas, $overlay,
            0, 0, 0, 0,
            $userW, $userH,
            $overlayW, $overlayH
        );

        imagedestroy($overlay);

        // Save as PNG
        $filename = sprintf('%d_%s.png', $this->userId(), bin2hex(random_bytes(8)));
        $savePath = $this->uploadsDir . $filename;

        if (!imagepng($canvas, $savePath, 6)) {
            imagedestroy($canvas);
            return null;
        }

        imagedestroy($canvas);

        // Return the web-relative path
        return '/uploads/' . $filename;
    }

    /**
     * Get list of available overlay images (from overlays directory).
     */
    private function getOverlays(): array
    {
        $overlays = [];
        $files = glob($this->overlaysDir . '*.png');

        if ($files) {
            foreach ($files as $file) {
                $id = pathinfo($file, PATHINFO_FILENAME);
                $overlays[] = [
                    'id'   => $id,
                    'name' => ucwords(str_replace(['-', '_'], ' ', $id)),
                    'path' => '/assets/overlays/' . basename($file),
                ];
            }
        }

        return $overlays;
    }

    /**
     * Human-readable upload error messages.
     */
    private function getUploadErrorMessage(int $code): string
    {
        return match ($code) {
            UPLOAD_ERR_INI_SIZE   => 'File exceeds server upload limit.',
            UPLOAD_ERR_FORM_SIZE  => 'File exceeds form upload limit.',
            UPLOAD_ERR_PARTIAL    => 'File was only partially uploaded.',
            UPLOAD_ERR_NO_FILE    => 'No file was selected for upload.',
            UPLOAD_ERR_NO_TMP_DIR => 'Server temp directory missing.',
            UPLOAD_ERR_CANT_WRITE => 'Failed to write file to disk.',
            default               => 'Unknown upload error.',
        };
    }
}
