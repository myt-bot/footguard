from fastapi import APIRouter

from ..schemas import (
    AiAdviceRequest,
    AiAdviceResponse,
    AiQuestionRequest,
    AiQuestionResponse,
)
from ..schemas import AiChatRequest, AiChatResponse
from ..services.ai_advisor_service import (
    generate_advice,
    generate_chat_answer,
    generate_question_answer,
)

router = APIRouter(prefix="/api/v1/ai", tags=["ai-advice"])


@router.post("/advice", response_model=AiAdviceResponse)
def create_ai_advice(payload: AiAdviceRequest) -> AiAdviceResponse:
    return generate_advice(payload)


@router.post("/question", response_model=AiQuestionResponse)
def answer_ai_question(payload: AiQuestionRequest) -> AiQuestionResponse:
    return generate_question_answer(payload)


@router.post("/chat", response_model=AiChatResponse)
def answer_ai_chat(payload: AiChatRequest) -> AiChatResponse:
    return generate_chat_answer(payload)
