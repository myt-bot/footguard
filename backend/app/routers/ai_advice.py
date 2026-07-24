from fastapi import APIRouter

from ..schemas import AiAdviceRequest, AiAdviceResponse
from ..services.ai_advisor_service import generate_advice

router = APIRouter(prefix="/api/v1/ai", tags=["ai-advice"])


@router.post("/advice", response_model=AiAdviceResponse)
def create_ai_advice(payload: AiAdviceRequest) -> AiAdviceResponse:
    return generate_advice(payload)
