from time import time
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from ..database import get_db
from ..repositories.command_repository import (
    CommandConflictError,
    CommandNotFoundError,
    apply_ack,
    pending_command,
    to_schema,
)
from ..schemas import AckRequest, PendingCommandResponse, RecordedResponse

router = APIRouter(prefix="/api/v1", tags=["commands"])


@router.get("/command/pending", response_model=PendingCommandResponse)
def get_pending_command(
    target: Literal["left", "right", "both"] | None = Query(default=None),
    session: Session = Depends(get_db),
) -> PendingCommandResponse:
    command = pending_command(session, target, int(time() * 1000))
    return PendingCommandResponse(command=to_schema(command) if command else None)


@router.post("/ack", response_model=RecordedResponse)
def record_ack(
    payload: AckRequest, session: Session = Depends(get_db)
) -> RecordedResponse:
    try:
        apply_ack(session, payload)
    except CommandNotFoundError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except CommandConflictError as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    return RecordedResponse(recorded=True)
