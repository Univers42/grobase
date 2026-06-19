<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Beach extends Model
{
    protected $fillable = [
        'name',
        'slug',
        'location_id',
        'created_by',
        'short_description',
        'description',
        'difficulty',
        'status',
        'published_at',
        'latitude',
        'longitude',
    ];

    protected function casts(): array
    {
        return [
            'published_at' => 'datetime',
            'latitude' => 'decimal:7',
            'longitude' => 'decimal:7',
        ];
    }

    public function location()
    {
        return $this->belongsTo(Location::class);
    }

    public function images()
    {
        return $this->hasMany(BeachImage::class)->orderBy('sort_order');
    }

    public function coverImage()
    {
        return $this->hasOne(BeachImage::class)->where('is_cover', true);
    }

    public function creator()
    {
        return $this->belongsTo(User::class, 'created_by');
    }

    public function comments()
    {
        return $this->hasMany(Comment::class);
    }

    public function amenities()
    {
        return $this->belongsToMany(Amenity::class);
    }

    public function favoritedByUsers()
    {
        return $this->belongsToMany(User::class, 'favorites');
    }
}
