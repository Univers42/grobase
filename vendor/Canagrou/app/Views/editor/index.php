<div class="max-w-[935px] mx-auto px-4 py-6 md:py-8">

    <!-- ── Page Header ── -->
    <div class="mb-6">
        <h1 class="text-2xl font-bold text-ig-text">Create New Post</h1>
        <p class="text-ig-muted text-sm mt-1">Capture from your webcam or upload an image, then add an overlay.</p>
    </div>

    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">

        <!-- ════════════════════════════════════════════════════════ -->
        <!-- MAIN SECTION: Camera / Upload + Overlays               -->
        <!-- ════════════════════════════════════════════════════════ -->
        <div class="lg:col-span-2 space-y-5">

            <!-- ── Input Mode Tabs ── -->
            <div class="flex gap-0 bg-white border border-ig-border rounded-lg overflow-hidden">
                <button id="tab-webcam" onclick="Camera.switchMode('webcam')"
                        class="flex-1 py-3 px-4 text-sm font-semibold transition-all bg-ig-bg text-ig-text border-b-2 border-ig-text">
                    <svg class="inline w-4 h-4 mr-1.5 -mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/>
                    </svg>
                    Webcam
                </button>
                <button id="tab-upload" onclick="Camera.switchMode('upload')"
                        class="flex-1 py-3 px-4 text-sm font-semibold transition-all text-ig-muted hover:text-ig-text border-b-2 border-transparent">
                    <svg class="inline w-4 h-4 mr-1.5 -mt-0.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                    </svg>
                    Upload
                </button>
            </div>

            <!-- ── Preview Area ── -->
            <div class="relative bg-white border border-ig-border rounded-lg overflow-hidden shadow-sm"
                 style="aspect-ratio: 4/3;">

                <!-- Webcam mode -->
                <div id="webcam-area" class="absolute inset-0">
                    <video id="webcam-video" autoplay playsinline muted
                           class="w-full h-full object-cover webcam-mirror"></video>
                    <canvas id="overlay-preview"
                            class="absolute inset-0 w-full h-full pointer-events-none"
                            style="z-index: 10;"></canvas>
                    <div id="webcam-status"
                         class="absolute inset-0 flex flex-col items-center justify-center bg-white z-20">
                        <svg class="w-16 h-16 text-gray-300 mb-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                                  d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"/>
                        </svg>
                        <p class="text-ig-muted text-sm">Starting webcam…</p>
                        <div class="spinner mt-3"></div>
                    </div>
                </div>

                <!-- Upload mode (hidden by default) -->
                <div id="upload-area" class="absolute inset-0 hidden">
                    <img id="upload-preview" src="" alt="Upload preview"
                         class="w-full h-full object-contain hidden" />
                    <canvas id="upload-overlay-preview"
                            class="absolute inset-0 w-full h-full pointer-events-none"
                            style="z-index: 10;"></canvas>
                    <div id="drop-zone"
                         class="absolute inset-0 flex flex-col items-center justify-center cursor-pointer
                                border-2 border-dashed border-gray-300 hover:border-ig-blue transition-colors m-4 rounded-lg">
                        <svg class="w-16 h-16 text-gray-300 mb-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                                  d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12"/>
                        </svg>
                        <p class="text-ig-text text-sm font-medium">Drag photos here</p>
                        <p class="text-ig-muted text-xs mt-1">JPEG, PNG or WebP — Max 5 MB</p>
                        <button type="button" onclick="document.getElementById('file-input').click()"
                                class="mt-4 px-4 py-2 bg-ig-blue text-white text-sm font-semibold rounded-lg hover:bg-blue-600 transition-colors">
                            Select from computer
                        </button>
                        <input id="file-input" type="file" accept="image/jpeg,image/png,image/webp" class="hidden" />
                    </div>
                </div>

                <!-- Flash / capture animation -->
                <div id="capture-flash" class="absolute inset-0 bg-white opacity-0 pointer-events-none transition-opacity z-30"></div>
            </div>

            <!-- ── Overlay Selection ── -->
            <div class="bg-white border border-ig-border rounded-lg p-4">
                <h2 class="text-sm font-semibold text-ig-text uppercase tracking-wider mb-3">
                    Choose an Overlay
                </h2>
                <div id="overlay-list" class="grid grid-cols-3 sm:grid-cols-5 md:grid-cols-6 lg:grid-cols-8 gap-2">
                    <?php foreach ($__raw['overlays'] as $overlay): ?>
                        <button class="overlay-thumb group relative aspect-square bg-ig-bg rounded-lg p-2
                                       flex items-center justify-center hover:bg-gray-100"
                                data-overlay-id="<?= htmlspecialchars($overlay['id']) ?>"
                                data-overlay-src="<?= htmlspecialchars($overlay['path']) ?>"
                                title="<?= htmlspecialchars($overlay['name']) ?>">
                            <img src="<?= htmlspecialchars($overlay['path']) ?>"
                                 alt="<?= htmlspecialchars($overlay['name']) ?>"
                                 class="w-full h-full object-contain" loading="lazy" />
                        </button>
                    <?php endforeach; ?>
                </div>
                <?php if (empty($__raw['overlays'])): ?>
                    <p class="text-ig-muted text-sm">No overlays available. Run <code class="bg-ig-bg px-1.5 py-0.5 rounded text-xs">make overlays</code> first.</p>
                <?php endif; ?>
            </div>

            <!-- ── Action buttons ── -->
            <div class="flex gap-3">
                <button id="capture-btn" disabled
                        onclick="Camera.capture()"
                        class="capture-btn flex-1 bg-ig-blue hover:bg-blue-600 disabled:bg-gray-200 disabled:text-gray-400
                               text-white font-semibold py-3 rounded-lg transition-all flex items-center justify-center gap-2 text-sm">
                    <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                              d="M3 9a2 2 0 012-2h.93a2 2 0 001.664-.89l.812-1.22A2 2 0 0110.07 4h3.86a2 2 0 011.664.89l.812 1.22A2 2 0 0018.07 7H19a2 2 0 012 2v9a2 2 0 01-2 2H5a2 2 0 01-2-2V9z"/>
                        <circle cx="12" cy="13" r="3"/>
                    </svg>
                    <span id="capture-btn-text">Select an overlay first</span>
                </button>
                <button id="gif-btn" disabled
                        onclick="Camera.captureGif()"
                        class="bg-purple-500 hover:bg-purple-600 disabled:bg-gray-200 disabled:text-gray-400
                               text-white font-semibold py-3 px-5 rounded-lg transition-all flex items-center justify-center gap-2 text-sm"
                        title="Capture animated GIF (webcam only)">
                    <svg class="w-5 h-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                              d="M14.752 11.168l-3.197-2.132A1 1 0 0010 9.87v4.263a1 1 0 001.555.832l3.197-2.132a1 1 0 000-1.664z"/>
                        <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                              d="M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                    </svg>
                    <span id="gif-btn-text">GIF</span>
                </button>
            </div>

            <!-- GIF Recording indicator -->
            <div id="gif-indicator" class="hidden bg-red-50 border border-red-200 rounded-lg px-4 py-3 flex items-center gap-3">
                <div class="w-3 h-3 rounded-full bg-red-500 animate-pulse"></div>
                <span class="text-red-600 text-sm font-medium">Recording GIF…</span>
                <span id="gif-frame-count" class="text-red-400 text-sm ml-auto">0 / 5 frames</span>
            </div>

        </div>

        <!-- ════════════════════════════════════════════════════════ -->
        <!-- SIDE SECTION: User's Previous Captures                  -->
        <!-- ════════════════════════════════════════════════════════ -->
        <div class="space-y-4">
            <h2 class="text-sm font-semibold text-ig-text uppercase tracking-wider">
                My Captures
                <span class="text-ig-blue ml-1">(<?= count($__raw['myImages']) ?>)</span>
            </h2>

            <div id="my-images" class="grid grid-cols-2 gap-2 max-h-[70vh] overflow-y-auto pr-1">
                <?php if (empty($__raw['myImages'])): ?>
                    <div id="no-images-msg" class="col-span-2 bg-white border border-ig-border rounded-lg text-center py-10">
                        <svg class="w-12 h-12 text-gray-300 mx-auto mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                                  d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                        </svg>
                        <p class="text-ig-muted text-sm">No captures yet</p>
                        <p class="text-gray-300 text-xs mt-1">Select an overlay to start!</p>
                    </div>
                <?php else: ?>
                    <?php foreach ($__raw['myImages'] as $img): ?>
                        <div class="group relative rounded-lg overflow-hidden bg-white border border-ig-border fade-in-up"
                             data-post-id="<?= (int)$img['id'] ?>">
                            <img src="<?= htmlspecialchars($img['image_path']) ?>"
                                 alt="Capture #<?= (int)$img['id'] ?>"
                                 class="w-full aspect-square object-cover" loading="lazy" />
                            <div class="absolute inset-0 bg-black/40
                                        opacity-0 group-hover:opacity-100 transition-opacity">
                                <div class="absolute bottom-2 left-2 right-2 flex justify-between items-center">
                                    <span class="text-xs text-white font-medium">
                                        <?= date('M j, H:i', strtotime($img['created_at'])) ?>
                                    </span>
                                    <button onclick="Camera.deleteImage(<?= (int)$img['id'] ?>)"
                                            class="p-1.5 bg-white/90 hover:bg-red-500 hover:text-white text-ig-text rounded-full transition-colors"
                                            title="Delete">
                                        <svg class="w-3.5 h-3.5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                                                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                                        </svg>
                                    </button>
                                </div>
                            </div>
                        </div>
                    <?php endforeach; ?>
                <?php endif; ?>
            </div>
        </div>

    </div>
</div>

<!-- Hidden canvas for capturing frames -->
<canvas id="capture-canvas" class="hidden"></canvas>

<!-- Camera JavaScript -->
<script src="/assets/js/camera.js"></script>
