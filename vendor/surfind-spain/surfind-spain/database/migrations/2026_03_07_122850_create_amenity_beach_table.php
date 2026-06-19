<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Run the migrations.
     */
    public function up(): void
    {
        Schema::create('amenity_beach', function (Blueprint $table) {
            $table->id();
            $table->foreignId('beach_id')
                ->constrained()
                ->onDelete('cascade');
            $table->foreignId('amenity_id')
                ->constrained()
                ->onDelete('cascade');
            $table->timestamps();

            $table->unique(['beach_id', 'amenity_id']);
        });
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        Schema::dropIfExists('amenity_beach');
    }
};
