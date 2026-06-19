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
        Schema::create('beaches', function (Blueprint $table) {
            $table->id();
            $table->string('name');
            $table->string('slug')->unique();
            $table->foreignId('location_id')
                ->constrained()
                ->onDelete('cascade');
            $table->foreignId('created_by')
                ->nullable()
                ->constrained('users')
                ->nullOnDelete();
            $table->string('short_description', 255)->nullable();
            $table->text('description')->nullable();
            $table->enum('difficulty', [
                'beginner',
                'intermediate',
                'advanced',
            ])->nullable();
            $table->enum('status', [
                'draft',
                'published',
                'archived',
            ])->default('draft');
            $table->timestamp('published_at')->nullable();
            $table->decimal('latitude', 10, 7);
            $table->decimal('longitude', 10, 7);
            $table->timestamps();
        });
    }

    /**
     * Reverse the migrations.
     */
    public function down(): void
    {
        Schema::dropIfExists('beaches');
    }
};
