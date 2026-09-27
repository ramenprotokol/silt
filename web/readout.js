// Text for the title block's measured readouts. Kept apart from app.js so
// the tests can check it without a page.

/**
 * The step-time line. It only ever shows a number measured on the current
 * grid: `stepMs` is null until the first timed batch on this grid. Until
 * then the line says "measuring…" if time is running, and says it has not
 * been timed yet if time is halted (nothing is being measured).
 */
export function stepTimeText(stepMs, surveyMs, grid, running = true) {
  if (stepMs == null || !Number.isFinite(stepMs)) {
    return running ? `measuring… (${grid}² grid)` : `not timed yet; timed once the survey runs (${grid}² grid)`;
  }
  const survey = surveyMs == null || !Number.isFinite(surveyMs) ? '' : `; rivers re-surveyed in ${surveyMs.toFixed(1)} ms every 16 steps`;
  return `${stepMs.toFixed(2)} ms per step${survey}, measured here (${grid}² grid)`;
}
