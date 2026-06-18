/**
 * Fuzzy Testing Index
 * Export all fuzzy testing utilities
 */

export { Fuzzer, fuzzer, createSeededFuzzer } from './fuzzer';
export type { FuzzStrategy, FuzzOptions } from './fuzzer';
export { MutationStrategy } from './strategies';
export type { MutationType, MutationResult } from './strategies';
