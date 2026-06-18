/**
 * CAMAGRU — Camera & Editor Logic
 * Handles: webcam, file upload, overlay preview (live), capture, delete.
 * Vanilla ES6+ — no frameworks.
 */

'use strict';

const Camera = {
    // State
    mode: 'webcam',
    stream: null,
    selectedOverlay: null,
    overlayImage: null,
    uploadedFile: null,
    uploadedImageEl: null,
    isBusy: false,

    // DOM refs (lazy-initialised)
    els: {},

    /**
     * Initialise all DOM references and event listeners.
     */
    init() {
        // Cache DOM elements
        this.els = {
            video:            document.getElementById('webcam-video'),
            webcamStatus:     document.getElementById('webcam-status'),
            webcamArea:       document.getElementById('webcam-area'),
            uploadArea:       document.getElementById('upload-area'),
            uploadPreview:    document.getElementById('upload-preview'),
            dropZone:         document.getElementById('drop-zone'),
            fileInput:        document.getElementById('file-input'),
            overlayPreview:   document.getElementById('overlay-preview'),
            uploadOverlay:    document.getElementById('upload-overlay-preview'),
            captureCanvas:    document.getElementById('capture-canvas'),
            captureBtn:       document.getElementById('capture-btn'),
            captureBtnText:   document.getElementById('capture-btn-text'),
            captureFlash:     document.getElementById('capture-flash'),
            overlayList:      document.getElementById('overlay-list'),
            myImages:         document.getElementById('my-images'),
            captureCount:     document.getElementById('capture-count'),
            tabWebcam:        document.getElementById('tab-webcam'),
            tabUpload:        document.getElementById('tab-upload'),
            noImagesMsg:      document.getElementById('no-images-msg'),
        };

        // Overlay selection
        this.els.overlayList.addEventListener('click', (e) => {
            const btn = e.target.closest('.overlay-thumb');
            if (btn) this.selectOverlay(btn);
        });

        // File upload events
        this.els.dropZone.addEventListener('click', () => this.els.fileInput.click());
        this.els.fileInput.addEventListener('change', (e) => this.handleFileSelect(e));

        // Drag and drop
        this.els.dropZone.addEventListener('dragover', (e) => {
            e.preventDefault();
            e.stopPropagation();
            this.els.dropZone.classList.add('border-blue-500', 'bg-blue-50');
        });
        this.els.dropZone.addEventListener('dragleave', (e) => {
            e.preventDefault();
            this.els.dropZone.classList.remove('border-blue-500', 'bg-blue-50');
        });
        this.els.dropZone.addEventListener('drop', (e) => {
            e.preventDefault();
            e.stopPropagation();
            this.els.dropZone.classList.remove('border-blue-500', 'bg-blue-50');
            if (e.dataTransfer.files.length) {
                this.handleFile(e.dataTransfer.files[0]);
            }
        });

        // Start webcam by default
        this.startWebcam();
    },

    /**
     * Switch between webcam and upload modes.
     */
    switchMode(mode) {
        this.mode = mode;

        // Update tabs
        const activeClasses  = ['text-blue-500', 'border-b-2', 'border-blue-500'];
        const defaultClasses = ['text-gray-500', 'hover:text-gray-800'];

        if (mode === 'webcam') {
            this.els.tabWebcam.classList.add(...activeClasses);
            this.els.tabWebcam.classList.remove(...defaultClasses);
            this.els.tabUpload.classList.remove(...activeClasses);
            this.els.tabUpload.classList.add(...defaultClasses);
            this.els.webcamArea.classList.remove('hidden');
            this.els.uploadArea.classList.add('hidden');
            this.startWebcam();
        } else {
            this.els.tabUpload.classList.add(...activeClasses);
            this.els.tabUpload.classList.remove(...defaultClasses);
            this.els.tabWebcam.classList.remove(...activeClasses);
            this.els.tabWebcam.classList.add(...defaultClasses);
            this.els.uploadArea.classList.remove('hidden');
            this.els.webcamArea.classList.add('hidden');
            this.stopWebcam();
        }

        this.updateCaptureButton();
        this.updateGifButton();
    },

    // ─── Webcam ────────────────────────────────────────────────────

    async startWebcam() {
        if (this.stream) return; // Already running

        this.els.webcamStatus.classList.remove('hidden');

        try {
            this.stream = await navigator.mediaDevices.getUserMedia({
                video: { width: { ideal: 1280 }, height: { ideal: 960 }, facingMode: 'user' },
                audio: false,
            });
            this.els.video.srcObject = this.stream;
            await this.els.video.play();

            // Hide status overlay
            this.els.webcamStatus.classList.add('hidden');

            // Start overlay rendering loop
            this.renderWebcamOverlay();
        } catch (err) {
            console.warn('Webcam not available:', err.message);
            this.els.webcamStatus.innerHTML = `
                <svg class="w-16 h-16 text-amber-500 mb-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                    <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                          d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>
                </svg>
                <p class="text-amber-600 text-sm font-medium">Webcam unavailable</p>
                <p class="text-gray-500 text-xs mt-1">Use the Upload tab instead</p>
            `;
        }
    },

    stopWebcam() {
        if (this.stream) {
            this.stream.getTracks().forEach(t => t.stop());
            this.stream = null;
        }
    },

    /**
     * Live overlay rendering on webcam preview (bonus: live preview).
     */
    renderWebcamOverlay() {
        if (this.mode !== 'webcam' || !this.stream) return;

        const canvas = this.els.overlayPreview;
        const video  = this.els.video;

        if (video.videoWidth === 0) {
            requestAnimationFrame(() => this.renderWebcamOverlay());
            return;
        }

        // Match canvas size to displayed video
        const rect = video.getBoundingClientRect();
        canvas.width  = rect.width * (window.devicePixelRatio || 1);
        canvas.height = rect.height * (window.devicePixelRatio || 1);
        canvas.style.width  = rect.width + 'px';
        canvas.style.height = rect.height + 'px';

        const ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, canvas.width, canvas.height);

        if (this.overlayImage) {
            // Draw overlay scaled to canvas (mirrored to match webcam)
            ctx.save();
            ctx.translate(canvas.width, 0);
            ctx.scale(-1, 1);
            ctx.drawImage(this.overlayImage, 0, 0, canvas.width, canvas.height);
            ctx.restore();
        }

        requestAnimationFrame(() => this.renderWebcamOverlay());
    },

    /**
     * Draw overlay on the upload preview canvas.
     */
    renderUploadOverlay() {
        const canvas = this.els.uploadOverlay;
        const img    = this.els.uploadPreview;

        if (!img.naturalWidth) return;

        const rect = img.getBoundingClientRect();
        canvas.width  = rect.width * (window.devicePixelRatio || 1);
        canvas.height = rect.height * (window.devicePixelRatio || 1);
        canvas.style.width  = rect.width + 'px';
        canvas.style.height = rect.height + 'px';

        const ctx = canvas.getContext('2d');
        ctx.clearRect(0, 0, canvas.width, canvas.height);

        if (this.overlayImage) {
            // Compute where the image actually is (object-contain fit)
            const imgAspect    = img.naturalWidth / img.naturalHeight;
            const canvasAspect = canvas.width / canvas.height;

            let drawW, drawH, drawX, drawY;
            if (imgAspect > canvasAspect) {
                drawW = canvas.width;
                drawH = canvas.width / imgAspect;
                drawX = 0;
                drawY = (canvas.height - drawH) / 2;
            } else {
                drawH = canvas.height;
                drawW = canvas.height * imgAspect;
                drawX = (canvas.width - drawW) / 2;
                drawY = 0;
            }

            ctx.drawImage(this.overlayImage, drawX, drawY, drawW, drawH);
        }
    },

    // ─── Overlay Selection ─────────────────────────────────────────

    selectOverlay(btn) {
        // Remove previous selection
        document.querySelectorAll('.overlay-thumb.selected').forEach(el => el.classList.remove('selected'));

        btn.classList.add('selected');
        this.selectedOverlay = btn.dataset.overlayId;

        // Load overlay image for live preview
        const img = new Image();
        img.crossOrigin = 'anonymous';
        img.onload = () => {
            this.overlayImage = img;
            // Re-render upload overlay if in upload mode
            if (this.mode === 'upload') {
                this.renderUploadOverlay();
            }
        };
        img.src = btn.dataset.overlaySrc;

        this.updateCaptureButton();
        this.updateGifButton();
    },

    updateCaptureButton() {
        const btn  = this.els.captureBtn;
        const text = this.els.captureBtnText;

        const canCapture = this.selectedOverlay && (
            (this.mode === 'webcam' && this.stream) ||
            (this.mode === 'upload' && this.uploadedFile)
        );

        btn.disabled = !canCapture;

        if (!this.selectedOverlay) {
            text.textContent = 'Select an overlay to capture';
        } else if (this.mode === 'upload' && !this.uploadedFile) {
            text.textContent = 'Upload an image first';
        } else if (canCapture) {
            text.textContent = this.mode === 'webcam' ? 'Capture Photo' : 'Apply & Save';
        }
    },

    // ─── File Upload ───────────────────────────────────────────────

    handleFileSelect(e) {
        if (e.target.files.length) {
            this.handleFile(e.target.files[0]);
        }
    },

    handleFile(file) {
        const allowed = ['image/jpeg', 'image/png', 'image/webp'];
        if (!allowed.includes(file.type)) {
            alert('Only JPEG, PNG and WebP images are accepted.');
            return;
        }
        if (file.size > 5 * 1024 * 1024) {
            alert('Image must be smaller than 5 MB.');
            return;
        }

        this.uploadedFile = file;

        // Show preview
        const reader = new FileReader();
        reader.onload = (e) => {
            this.els.uploadPreview.src = e.target.result;
            this.els.uploadPreview.classList.remove('hidden');
            this.els.dropZone.classList.add('hidden');
            this.els.uploadPreview.onload = () => this.renderUploadOverlay();
        };
        reader.readAsDataURL(file);

        this.updateCaptureButton();
    },

    // ─── Capture ───────────────────────────────────────────────────

    async capture() {
        if (this.isBusy || !this.selectedOverlay) return;
        this.isBusy = true;

        const btn  = this.els.captureBtn;
        const text = this.els.captureBtnText;
        btn.disabled = true;
        text.textContent = 'Processing…';

        try {
            if (this.mode === 'webcam') {
                await this.captureWebcam();
            } else {
                await this.captureUpload();
            }
        } catch (err) {
            console.error('Capture failed:', err);
            alert(err.error || err.message || 'Capture failed. Please try again.');
        } finally {
            this.isBusy = false;
            this.updateCaptureButton();
        }
    },

    /**
     * Capture frame from webcam, send base64 to server.
     */
    async captureWebcam() {
        const video  = this.els.video;
        const canvas = this.els.captureCanvas;

        // Set canvas to video native resolution
        canvas.width  = video.videoWidth;
        canvas.height = video.videoHeight;
        const ctx = canvas.getContext('2d');

        // Draw mirrored video frame (webcam is mirrored in CSS)
        ctx.save();
        ctx.translate(canvas.width, 0);
        ctx.scale(-1, 1);
        ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
        ctx.restore();

        // Get base64 png
        const imageData = canvas.toDataURL('image/png');

        // Flash effect
        this.flashEffect();

        // Send to server
        const result = await App.post('/editor/capture', {
            image:   imageData,
            overlay: this.selectedOverlay,
        });

        this.onCaptureSuccess(result);
    },

    /**
     * Upload file to server for server-side composition.
     */
    async captureUpload() {
        if (!this.uploadedFile) return;

        const formData = new FormData();
        formData.append('image', this.uploadedFile);
        formData.append('overlay', this.selectedOverlay);

        this.flashEffect();

        const result = await App.post('/editor/upload', formData);
        this.onCaptureSuccess(result);
    },

    /**
     * Handle successful capture — prepend new image to sidebar.
     */
    onCaptureSuccess(result) {
        if (!result.success) {
            alert(result.error || 'Unknown error');
            return;
        }

        // Remove "no images" message
        const noMsg = this.els.noImagesMsg;
        if (noMsg) noMsg.remove();

        // Create new thumbnail
        const div = document.createElement('div');
        div.className = 'group relative rounded-xl overflow-hidden bg-white border border-gray-200 fade-in-up';
        div.dataset.postId = result.post_id;
        div.innerHTML = `
            <img src="${result.image}" alt="Capture #${result.post_id}"
                 class="w-full aspect-square object-cover" />
            <div class="absolute inset-0 bg-gradient-to-t from-black/70 via-transparent to-transparent
                        opacity-0 group-hover:opacity-100 transition-opacity">
                <div class="absolute bottom-2 left-2 right-2 flex justify-between items-center">
                    <span class="text-xs text-white">Just now</span>
                    <button onclick="Camera.deleteImage(${result.post_id})"
                            class="p-1.5 bg-red-600/80 hover:bg-red-500 rounded-lg transition-colors"
                            title="Delete">
                        <svg class="w-4 h-4 text-white" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"/>
                        </svg>
                    </button>
                </div>
            </div>
        `;

        this.els.myImages.prepend(div);

        // Update count
        const count = this.els.myImages.querySelectorAll('[data-post-id]').length;
        this.els.captureCount.textContent = `(${count})`;
    },

    /**
     * Delete a user image via AJAX.
     */
    async deleteImage(postId) {
        if (!confirm('Delete this image?')) return;

        try {
            await App.delete(`/editor/delete/${postId}`);

            // Remove from DOM
            const el = this.els.myImages.querySelector(`[data-post-id="${postId}"]`);
            if (el) {
                el.style.transition = 'opacity 0.3s, transform 0.3s';
                el.style.opacity = '0';
                el.style.transform = 'scale(0.9)';
                setTimeout(() => el.remove(), 300);
            }

            // Update count
            setTimeout(() => {
                const count = this.els.myImages.querySelectorAll('[data-post-id]').length;
                this.els.captureCount.textContent = `(${count})`;

                if (count === 0) {
                    this.els.myImages.innerHTML = `
                        <div id="no-images-msg" class="col-span-2 text-center py-12">
                            <svg class="w-12 h-12 text-gray-300 mx-auto mb-3" fill="none" viewBox="0 0 24 24" stroke="currentColor">
                                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5"
                                      d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2-2H6a2 2 0 00-2 2v12a2 2 0 002 2z"/>
                            </svg>
                            <p class="text-gray-500 text-sm">No captures yet</p>
                            <p class="text-gray-400 text-xs mt-1">Start by selecting an overlay!</p>
                        </div>
                    `;
                }
            }, 350);
        } catch (err) {
            alert(err.error || 'Failed to delete image.');
        }
    },

    /**
     * White flash animation when capturing.
     */
    flashEffect() {
        const flash = this.els.captureFlash;
        flash.style.transition = 'none';
        flash.style.opacity = '0.8';
        requestAnimationFrame(() => {
            flash.style.transition = 'opacity 0.5s ease-out';
            flash.style.opacity = '0';
        });
    },

    // ─── GIF Capture (Bonus) ───────────────────────────────────────

    gifFrames: [],
    gifRecording: false,
    GIF_FRAME_COUNT: 5,
    GIF_FRAME_INTERVAL: 400, // ms between frames

    /**
     * Capture an animated GIF from webcam frames (webcam mode only).
     */
    async captureGif() {
        if (this.isBusy || !this.selectedOverlay) return;
        if (this.mode !== 'webcam' || !this.stream) {
            alert('GIF capture requires an active webcam.');
            return;
        }

        this.isBusy = true;
        this.gifRecording = true;
        this.gifFrames = [];

        const gifBtn = document.getElementById('gif-btn');
        const gifIndicator = document.getElementById('gif-indicator');
        const gifCount = document.getElementById('gif-frame-count');
        const captureBtn = this.els.captureBtn;

        gifBtn.disabled = true;
        captureBtn.disabled = true;
        gifIndicator.classList.remove('hidden');

        try {
            // Capture frames at intervals
            for (let i = 0; i < this.GIF_FRAME_COUNT; i++) {
                gifCount.textContent = `${i + 1} / ${this.GIF_FRAME_COUNT} frames`;

                // Capture current webcam frame
                const canvas = this.els.captureCanvas;
                const video = this.els.video;
                canvas.width = video.videoWidth;
                canvas.height = video.videoHeight;
                const ctx = canvas.getContext('2d');

                // Mirror
                ctx.save();
                ctx.translate(canvas.width, 0);
                ctx.scale(-1, 1);
                ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
                ctx.restore();

                const frameData = canvas.toDataURL('image/png');
                this.gifFrames.push(frameData);

                // Flash each frame
                this.flashEffect();

                // Wait between frames
                if (i < this.GIF_FRAME_COUNT - 1) {
                    await new Promise(r => setTimeout(r, this.GIF_FRAME_INTERVAL));
                }
            }

            gifCount.textContent = 'Sending to server…';

            // Send all frames to server
            const result = await App.post('/editor/capture-gif', {
                frames: this.gifFrames,
                overlay: this.selectedOverlay,
            });

            this.onCaptureSuccess(result);
        } catch (err) {
            console.error('GIF capture failed:', err);
            alert(err.error || err.message || 'GIF capture failed. Please try again.');
        } finally {
            this.isBusy = false;
            this.gifRecording = false;
            this.gifFrames = [];
            gifIndicator.classList.add('hidden');
            this.updateCaptureButton();
            this.updateGifButton();
        }
    },

    /**
     * Update the GIF button state.
     */
    updateGifButton() {
        const btn = document.getElementById('gif-btn');
        if (!btn) return;
        btn.disabled = !(this.selectedOverlay && this.mode === 'webcam' && this.stream && !this.isBusy);
    },
};

// Boot
document.addEventListener('DOMContentLoaded', () => Camera.init());
