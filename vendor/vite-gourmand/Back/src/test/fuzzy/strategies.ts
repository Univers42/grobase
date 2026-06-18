/**
 * Mutation Strategies for Fuzzy Testing
 * Provides various ways to mutate valid inputs into potentially invalid ones
 */

export type MutationType =
  | 'bitflip' // Flip random bits
  | 'byteflip' // Flip random bytes
  | 'insert' // Insert random characters
  | 'delete' // Delete random characters
  | 'replace' // Replace random characters
  | 'swap' // Swap adjacent characters
  | 'duplicate' // Duplicate portions
  | 'truncate' // Truncate at random position
  | 'extend' // Extend with random data
  | 'case' // Change case
  | 'unicode' // Insert unicode characters
  | 'special'; // Insert special characters

export interface MutationResult {
  original: string;
  mutated: string;
  mutations: MutationType[];
  description: string;
}

export class MutationStrategy {
  /**
   * Apply a specific mutation type
   */
  static mutate(input: string, type: MutationType): MutationResult {
    let mutated = input;
    let description = '';

    switch (type) {
      case 'bitflip':
        if (input.length > 0) {
          const pos = Math.floor(Math.random() * input.length);
          const charCode = input.charCodeAt(pos);
          const bitPos = Math.floor(Math.random() * 8);
          const newCharCode = charCode ^ (1 << bitPos);
          mutated =
            input.substring(0, pos) +
            String.fromCharCode(newCharCode) +
            input.substring(pos + 1);
          description = `Flipped bit ${bitPos} at position ${pos}`;
        }
        break;

      case 'byteflip':
        if (input.length > 0) {
          const pos = Math.floor(Math.random() * input.length);
          const newChar = String.fromCharCode(Math.floor(Math.random() * 256));
          mutated =
            input.substring(0, pos) + newChar + input.substring(pos + 1);
          description = `Replaced byte at position ${pos}`;
        }
        break;

      case 'insert':
        {
          const pos = Math.floor(Math.random() * (input.length + 1));
          const insertChars = 'abcdefghijklmnopqrstuvwxyz0123456789!@#$%^&*()';
          const toInsert =
            insertChars[Math.floor(Math.random() * insertChars.length)];
          mutated = input.substring(0, pos) + toInsert + input.substring(pos);
          description = `Inserted '${toInsert}' at position ${pos}`;
        }
        break;

      case 'delete':
        if (input.length > 0) {
          const pos = Math.floor(Math.random() * input.length);
          mutated = input.substring(0, pos) + input.substring(pos + 1);
          description = `Deleted character at position ${pos}`;
        }
        break;

      case 'replace':
        if (input.length > 0) {
          const pos = Math.floor(Math.random() * input.length);
          const replaceChars = 'abcdefghijklmnopqrstuvwxyz0123456789';
          const replacement =
            replaceChars[Math.floor(Math.random() * replaceChars.length)];
          mutated =
            input.substring(0, pos) + replacement + input.substring(pos + 1);
          description = `Replaced character at position ${pos} with '${replacement}'`;
        }
        break;

      case 'swap':
        if (input.length > 1) {
          const pos = Math.floor(Math.random() * (input.length - 1));
          mutated =
            input.substring(0, pos) +
            input[pos + 1] +
            input[pos] +
            input.substring(pos + 2);
          description = `Swapped characters at positions ${pos} and ${pos + 1}`;
        }
        break;

      case 'duplicate':
        if (input.length > 0) {
          const start = Math.floor(Math.random() * input.length);
          const len = Math.min(
            Math.floor(Math.random() * 10) + 1,
            input.length - start,
          );
          const toDuplicate = input.substring(start, start + len);
          mutated = input + toDuplicate;
          description = `Duplicated '${toDuplicate}' at end`;
        }
        break;

      case 'truncate':
        if (input.length > 0) {
          const pos = Math.floor(Math.random() * input.length);
          mutated = input.substring(0, pos);
          description = `Truncated at position ${pos}`;
        }
        break;

      case 'extend':
        {
          const extendChars = 'AAAA\x00\xFF\n\r\t';
          const toAdd = extendChars[
            Math.floor(Math.random() * extendChars.length)
          ].repeat(Math.floor(Math.random() * 100) + 1);
          mutated = input + toAdd;
          description = `Extended with ${toAdd.length} characters`;
        }
        break;

      case 'case':
        {
          const pos = Math.floor(Math.random() * input.length);
          const char = input[pos];
          const newChar =
            char === char.toUpperCase()
              ? char.toLowerCase()
              : char.toUpperCase();
          mutated =
            input.substring(0, pos) + newChar + input.substring(pos + 1);
          description = `Changed case at position ${pos}`;
        }
        break;

      case 'unicode':
        {
          const unicodeChars = [
            '\u0000', // Null
            '\uFFFF', // Max BMP
            '\u202E', // RTL override
            '\u200B', // Zero-width space
            '\uFEFF', // BOM
            '🔐', // Emoji
            '中', // Chinese
            'й', // Cyrillic
          ];
          const pos = Math.floor(Math.random() * (input.length + 1));
          const toInsert =
            unicodeChars[Math.floor(Math.random() * unicodeChars.length)];
          mutated = input.substring(0, pos) + toInsert + input.substring(pos);
          description = `Inserted unicode at position ${pos}`;
        }
        break;

      case 'special':
        {
          const specialChars = [
            '<',
            '>',
            '"',
            "'",
            '&',
            ';',
            '|',
            '$',
            '`',
            '\\',
            '\n',
            '\r',
            '\t',
            '\0',
          ];
          const pos = Math.floor(Math.random() * (input.length + 1));
          const toInsert =
            specialChars[Math.floor(Math.random() * specialChars.length)];
          mutated = input.substring(0, pos) + toInsert + input.substring(pos);
          description = `Inserted special char at position ${pos}`;
        }
        break;
    }

    return {
      original: input,
      mutated,
      mutations: [type],
      description,
    };
  }

  /**
   * Apply multiple random mutations
   */
  static multiMutate(input: string, count: number = 3): MutationResult {
    const mutationTypes: MutationType[] = [
      'bitflip',
      'byteflip',
      'insert',
      'delete',
      'replace',
      'swap',
      'duplicate',
      'truncate',
      'extend',
      'case',
      'unicode',
      'special',
    ];

    let current = input;
    const appliedMutations: MutationType[] = [];
    const descriptions: string[] = [];

    for (let i = 0; i < count; i++) {
      const type =
        mutationTypes[Math.floor(Math.random() * mutationTypes.length)];
      const result = this.mutate(current, type);
      current = result.mutated;
      appliedMutations.push(type);
      descriptions.push(result.description);
    }

    return {
      original: input,
      mutated: current,
      mutations: appliedMutations,
      description: descriptions.join('; '),
    };
  }

  /**
   * Generate variations of a valid input
   */
  static generateVariations(
    input: string,
    count: number = 10,
  ): MutationResult[] {
    const results: MutationResult[] = [];

    for (let i = 0; i < count; i++) {
      const mutationCount = Math.floor(Math.random() * 3) + 1;
      results.push(this.multiMutate(input, mutationCount));
    }

    return results;
  }

  /**
   * Generate edge case variations
   */
  static generateEdgeCases(input: string): string[] {
    return [
      '', // Empty
      ' ', // Single space
      input, // Original
      input.toUpperCase(), // All caps
      input.toLowerCase(), // All lower
      ' ' + input, // Leading space
      input + ' ', // Trailing space
      ' ' + input + ' ', // Both spaces
      input.repeat(2), // Duplicated
      input.substring(0, Math.floor(input.length / 2)), // First half
      input.substring(Math.floor(input.length / 2)), // Second half
      input.split('').reverse().join(''), // Reversed
      input.replace(/./g, '*'), // All asterisks
      input + '\x00', // Null terminator
      input + '\n', // Newline
      '\t' + input, // Tab prefix
    ];
  }
}
