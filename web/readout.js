// Text for the title block's measured readouts. Kept apart from app.js so
// the tests can check it without a page.

/**
 * The step-time line. It only ever shows a number measured on the current
 * grid: `stepMs` is null until the first timed batch after a survey starts
 * (or the grid changes), and then the line says "measuring…".
 */
export function stepTimeText(stepMs, surveyMs, grid) {
  if (stepMs == null || !Number.isFinite(stepMs)) return `measuring… (${grid}² grid)`;
  const survey = surveyMs == null || !Number.isFinite(surveyMs) ? '' : `; rivers re-surveyed in ${surveyMs.toFixed(1)} ms every 16 steps`;
  return `${stepMs.toFixed(2)} ms per step${survey}, measured here (${grid}² grid)`;
}
