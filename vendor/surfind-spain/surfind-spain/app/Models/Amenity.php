<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

class Amenity extends Model
{
    protected $fillable = [
        'name',
        'icon',
    ];

    public function beaches()
    {
        return $this->belongsToMany(Beach::class);
    }
}
