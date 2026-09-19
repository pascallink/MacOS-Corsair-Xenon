'use strict';
/**
 * Gemeinsamer Anthropic-Client fuer die CI-Skripte.
 * Ein Ort fuer Modell-ID und Retry-Verhalten - damit beide Workflows
 * nicht auseinanderlaufen.
 */

const API_URL = 'https://api.anthropic.com/v1/messages';
const API_VERSION = '2023-06-01';
const MODEL = 'claude-haiku-4-5';

/**
 * Fehler, bei dem das Modell nicht erreichbar war oder nichts geliefert hat -
 * fehlender Schluessel, leeres Guthaben, Ratsperre, Stoerung. Beides sind
 * Zustaende ausserhalb dieses Repos; die aufrufenden Jobs liefern nur Beiwerk
 * und sollen daran nicht scheitern. Fehler im eigenen Code tragen die
 * Markierung nicht und bleiben hart.
 */
class ModelUnavailableError extends Error {
  constructor(message) {
    super(message);
    this.name = 'ModelUnavailableError';
    this.modelUnavailable = true;
  }
}

/**
 * @param {unknown} error
 * @returns {boolean} true, wenn der Fehler vom Modell kommt und nicht vom Code
 */
function isModelUnavailable(error) {
  return !!(error && error.modelUnavailable);
}

/**
 * @param {{system: string, user: string, maxTokens: number}} opts
 * @returns {Promise<string>} Antworttext des Modells
 */
async function askClaude({ system, user, maxTokens }) {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new ModelUnavailableError('Missing env var: ANTHROPIC_API_KEY');

  const payload = JSON.stringify({
    model: MODEL,
    max_tokens: maxTokens,
    system,
    messages: [{ role: 'user', content: user }],
  });

  for (let attempt = 0; attempt < 3; attempt++) {
    const res = await fetch(API_URL, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': API_VERSION,
      },
      body: payload,
    });

    if (res.ok) {
      const data = await res.json();
      const text = (data.content || [])
        .filter((block) => block.type === 'text')
        .map((block) => block.text)
        .join('')
        .trim();
      if (!text) throw new ModelUnavailableError('Anthropic API lieferte keinen Text zurueck');
      return text;
    }

    const detail = await res.text();
    const retryable = res.status === 429 || res.status >= 500;
    if (!retryable || attempt === 2) {
      throw new ModelUnavailableError(`Anthropic API ${res.status}: ${detail}`);
    }
    await new Promise((r) => setTimeout(r, 2000 * 2 ** attempt));
  }
}

module.exports = { askClaude, isModelUnavailable, ModelUnavailableError, MODEL };
