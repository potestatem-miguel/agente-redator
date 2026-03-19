# Notes

Use este skill para devolver materia-prima de pesquisa, nao decisoes finais.

Campos mais importantes para as proximas etapas:

- `seed_keyword`
- `candidate_queries`
- `people_also_ask`
- `related_searches`
- `organic_highlights`
- `search_intent_summary`
- `snippet_opportunities`

Fonte operacional:

- Google Search via SerpApi
- Google Trends `RELATED_QUERIES` via SerpApi

Se Trends nao responder, retornar `partial` em vez de falhar o job inteiro.
