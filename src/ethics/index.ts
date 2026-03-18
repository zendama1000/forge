/**
 * 倫理チェックモジュール - 公開 API
 */

export type { ViolationResult, DetectionResult } from './expression-detector';
export { detectViolations } from './expression-detector';
export type { ProhibitedExpression } from './ethics-data';
export { PROHIBITED_EXPRESSIONS } from './ethics-data';
