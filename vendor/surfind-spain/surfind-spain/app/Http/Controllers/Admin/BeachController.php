<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\Amenity;
use App\Models\Beach;
use App\Models\Location;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\View\View;

class BeachController extends Controller
{
    public function index(Request $request): View
    {
        $filters = $request->validate([
            'search' => ['nullable', 'string', 'max:255'],
            'location_id' => ['nullable', 'integer', 'exists:locations,id'],
            'status' => ['nullable', Rule::in(['all', 'draft', 'published', 'archived'])],
            'difficulty' => ['nullable', Rule::in(['all', 'beginner', 'intermediate', 'advanced'])],
        ]);

        $search = $filters['search'] ?? null;
        $locationId = $filters['location_id'] ?? null;
        $status = $filters['status'] ?? 'all';
        $difficulty = $filters['difficulty'] ?? 'all';

        $beaches = Beach::query()
            ->with(['location', 'coverImage', 'creator'])
            ->withCount(['comments', 'favoritedByUsers'])
            ->when($search, function ($query, string $search) {
                $query->where(function ($query) use ($search) {
                    $query
                        ->where('name', 'like', "%{$search}%")
                        ->orWhere('short_description', 'like', "%{$search}%");
                });
            })
            ->when($locationId, fn ($query) => $query->where('location_id', $locationId))
            ->when($status !== 'all', fn ($query) => $query->where('status', $status))
            ->when($difficulty !== 'all', fn ($query) => $query->where('difficulty', $difficulty))
            ->latest()
            ->paginate(10)
            ->withQueryString();

        return view('admin.beaches.index', [
            'beaches' => $beaches,
            'locations' => Location::orderBy('name')->get(),
            'difficulties' => $this->difficulties(),
            'statuses' => $this->statuses(),
            'search' => $search,
            'locationId' => $locationId,
            'status' => $status,
            'difficulty' => $difficulty,
        ]);
    }

    public function create(): View
    {
        return view('admin.beaches.create', $this->formData());
    }

    public function store(Request $request): RedirectResponse
    {
        $validated = $this->validateBeach($request);

        $beach = DB::transaction(function () use ($request, $validated) {
            $beach = Beach::create($this->beachAttributes($validated) + [
                'created_by' => auth()->id(),
            ]);

            $beach->amenities()->sync($validated['amenities'] ?? []);
            $this->storeCoverImage($request, $beach, $validated);

            return $beach;
        });

        return redirect()
            ->route('admin.beaches.show', $beach)
            ->with('status', 'La playa ha sido creada correctamente.');
    }

    public function show(Beach $beach): View
    {
        $beach->load(['location', 'coverImage', 'creator', 'amenities'])
            ->loadCount(['comments', 'favoritedByUsers']);

        return view('admin.beaches.show', compact('beach'));
    }

    public function edit(Beach $beach): View
    {
        $beach->load(['amenities', 'coverImage', 'location']);

        return view('admin.beaches.edit', $this->formData($beach));
    }

    public function update(Request $request, Beach $beach): RedirectResponse
    {
        $validated = $this->validateBeach($request, $beach);

        DB::transaction(function () use ($request, $beach, $validated) {
            $beach->update($this->beachAttributes($validated));
            $beach->amenities()->sync($validated['amenities'] ?? []);
            $this->storeCoverImage($request, $beach, $validated);
        });

        return redirect()
            ->route('admin.beaches.show', $beach)
            ->with('status', 'La playa ha sido actualizada correctamente.');
    }

    public function destroy(Beach $beach): RedirectResponse
    {
        $beach->update([
            'status' => 'archived',
            'published_at' => null,
        ]);

        return redirect()
            ->route('admin.beaches.index')
            ->with('status', 'La playa ha sido archivada.');
    }

    private function formData(?Beach $beach = null): array
    {
        return [
            'beach' => $beach,
            'locations' => Location::orderBy('name')->get(),
            'amenities' => Amenity::orderBy('name')->get(),
            'difficulties' => $this->difficulties(),
            'statuses' => $this->statuses(),
        ];
    }

    private function validateBeach(Request $request, ?Beach $beach = null): array
    {
        if ($request->filled('name')) {
            $request->merge(['slug' => Str::slug($request->input('name'))]);
        }

        return $request->validate([
            'name' => ['required', 'string', 'max:255'],
            'slug' => ['required', 'string', 'max:255', Rule::unique('beaches', 'slug')->ignore($beach)],
            'location_id' => ['required', 'integer', 'exists:locations,id'],
            'short_description' => ['nullable', 'string', 'max:255'],
            'description' => ['nullable', 'string'],
            'difficulty' => ['nullable', Rule::in(array_keys($this->difficulties()))],
            'status' => ['required', Rule::in(array_keys($this->statuses()))],
            'latitude' => ['required', 'numeric', 'between:-90,90'],
            'longitude' => ['required', 'numeric', 'between:-180,180'],
            'amenities' => ['nullable', 'array'],
            'amenities.*' => ['integer', 'exists:amenities,id'],
            'cover_source' => ['nullable', Rule::in(['upload', 'url'])],
            'cover_image' => ['nullable', 'required_if:cover_source,upload', 'image', 'mimes:jpg,jpeg,png,webp', 'max:4096'],
            'cover_image_url' => ['nullable', 'required_if:cover_source,url', 'url', 'max:2048'],
            'cover_alt_text' => ['nullable', 'string', 'max:255'],
        ]);
    }

    private function beachAttributes(array $validated): array
    {
        return [
            'name' => $validated['name'],
            'slug' => $validated['slug'],
            'location_id' => $validated['location_id'],
            'short_description' => $validated['short_description'] ?? null,
            'description' => $validated['description'] ?? null,
            'difficulty' => $validated['difficulty'] ?? null,
            'status' => $validated['status'],
            'published_at' => $validated['status'] === 'published'
                ? now()
                : null,
            'latitude' => $validated['latitude'],
            'longitude' => $validated['longitude'],
        ];
    }

    private function storeCoverImage(Request $request, Beach $beach, array $validated): void
    {
        if (empty($validated['cover_source'])) {
            return;
        }

        $beach->images()->update(['is_cover' => false]);

        $attributes = [
            'user_id' => auth()->id(),
            'source_type' => $validated['cover_source'],
            'is_cover' => true,
            'sort_order' => 0,
            'alt_text' => $validated['cover_alt_text'] ?? $beach->name,
        ];

        if ($validated['cover_source'] === 'upload') {
            /** @var UploadedFile $image */
            $image = $request->file('cover_image');
            $attributes['path'] = $image->store('beaches', 'public');
        }

        if ($validated['cover_source'] === 'url') {
            $attributes['external_url'] = $validated['cover_image_url'];
        }

        $beach->images()->create($attributes);
    }

    private function difficulties(): array
    {
        return [
            'beginner' => 'Principiante',
            'intermediate' => 'Intermedia',
            'advanced' => 'Avanzada',
        ];
    }

    private function statuses(): array
    {
        return [
            'draft' => 'Borrador',
            'published' => 'Publicada',
            'archived' => 'Archivada',
        ];
    }
}
