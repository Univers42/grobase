<?php
use App\Core\View;
use App\Core\Session;
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>404 — Page Not Found | Camagru</title>
    <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="min-h-screen bg-[#fafafa] text-gray-800 flex items-center justify-center">
    <div class="text-center px-6">
        <div class="text-8xl font-bold text-gray-300 mb-4">404</div>
        <h1 class="text-2xl font-bold text-gray-800 mb-2">Page Not Found</h1>
        <p class="text-gray-500 mb-8 max-w-md">The page you're looking for doesn't exist or has been moved.</p>
        <a href="/" class="inline-block px-6 py-3 rounded-lg font-semibold text-white bg-[#0095f6] hover:bg-[#1877f2] transition-all">
            Back to Gallery
        </a>
    </div>
</body>
</html>
