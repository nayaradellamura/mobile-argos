"""Roda as avaliações (evals) dos agentes ADK com o `AgentEvaluator`.

NÃO roda no CI: precisa do Gemini (chave de API) e do emulador do
Firestore com o seed de `eval/seed_eval.py`. Ver `eval/README.md`.

Uso (de dentro de adk_agents/):
    .venv\\Scripts\\python.exe eval\\run_evals.py                 # os dois times
    .venv\\Scripts\\python.exe eval\\run_evals.py orcamento_team  # só um
    .venv\\Scripts\\python.exe eval\\run_evals.py --runs 1        # 1 execução por caso
"""

from __future__ import annotations

import argparse
import asyncio
import os
import sys

ADK_AGENTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ADK_AGENTS_DIR)

TIMES = ("orcamento_team", "vistoria_team")


def _carregar_env() -> None:
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    # Não sobrescreve o que já estiver exportado na sessão.
    load_dotenv(os.path.join(ADK_AGENTS_DIR, ".env"), override=False)


async def _avaliar(time: str, runs: int) -> None:
    from google.adk.evaluation.agent_evaluator import AgentEvaluator

    await AgentEvaluator.evaluate(
        agent_module=f"{time}.agent",
        eval_dataset_file_path_or_dir=os.path.join(ADK_AGENTS_DIR, time, "eval"),
        num_runs=runs,
        print_detailed_results=True,
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("times", nargs="*", default=list(TIMES), choices=TIMES)
    parser.add_argument("--runs", type=int, default=2, help="execuções por caso (default 2)")
    args = parser.parse_args()

    _carregar_env()

    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        sys.exit(
            "FIRESTORE_EMULATOR_HOST não está setado. As avaliações gravam no "
            "Firestore e só devem rodar contra o emulador (ver eval/README.md)."
        )
    if not (os.environ.get("GOOGLE_API_KEY") or os.environ.get("GOOGLE_GENAI_USE_VERTEXAI", "").upper() == "TRUE"):
        sys.exit("Defina GOOGLE_API_KEY (AI Studio) ou configure Vertex AI.")

    falhas = []
    for time in args.times:
        print(f"\n=== Avaliando {time} ===")
        try:
            asyncio.run(_avaliar(time, args.runs))
            print(f"{time}: OK")
        except AssertionError as erro:
            falhas.append(time)
            print(f"{time}: FALHOU\n{erro}")

    sys.exit(1 if falhas else 0)


if __name__ == "__main__":
    main()
