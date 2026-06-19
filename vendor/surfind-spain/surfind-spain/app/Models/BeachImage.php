<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\Storage;

class BeachImage extends Model
{
    protected $fillable = [
        'beach_id',
        'user_id',
        'source_type',
        'path',
        'external_url',
        'is_cover',
        'sort_order',
        'alt_text',
    ];

    protected function casts(): array
    {
        return [
            'is_cover' => 'boolean',
            'sort_order' => 'integer',
        ];
    }

    public function beach()
    {
        return $this->belongsTo(Beach::class);
    }

    public function user()
    {
        return $this->belongsTo(User::class);
    }

    public function url(): ?string
    {
        return $this->source_type === 'upload'
            ? ($this->path ? Storage::disk('public')->url($this->path) : null)
            : $this->external_url;
    }
}
