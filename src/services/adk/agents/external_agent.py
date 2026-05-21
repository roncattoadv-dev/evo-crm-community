"""
External agent for integrating with external providers (Flowise, N8N, Typebot, Dify, OpenAI).
"""

from google.adk.agents import BaseAgent
from google.adk.agents.invocation_context import InvocationContext
from google.adk.events import Event
from google.genai.types import Content, Part
from sqlalchemy.orm import Session
from typing import AsyncGenerator, Dict, Any
import logging

from src.services.providers import (
    FlowiseService,
    N8NService,
    DifyService,
    OpenAIService,
    TypebotService,
)

logger = logging.getLogger(__name__)


class ExternalAgent(BaseAgent):
    """
    Custom agent that integrates with external providers.
    
    This agent implements the interaction with external AI services
    like Flowise, N8N, Typebot, Dify, and OpenAI.
    """

    # Field declarations for Pydantic
    provider: str
    integration_config: Dict[str, Any]
    db: Session
    provider_service: Any = None

    def __init__(
        self,
        name: str,
        provider: str,
        integration_config: Dict[str, Any],
        db: Session,
        sub_agents: list = [],
        **kwargs,
    ):
        """
        Initialize the External agent.

        Args:
            name: Agent name
            provider: Provider name ('flowise', 'n8n', 'typebot', 'dify', 'openai')
            integration_config: Configuration from evo_core_agent_integrations.config
            db: Database session
            sub_agents: List of sub-agents to be executed after the External agent
        """
        super().__init__(
            name=name,
            provider=provider,
            integration_config=integration_config,
            db=db,
            sub_agents=sub_agents,
            **kwargs,
        )
        
        # Initialize provider service
        self.provider_service = self._create_provider_service(provider, integration_config)

    def _create_provider_service(self, provider: str, config: Dict[str, Any]):
        """Create the appropriate provider service instance."""
        try:
            if provider == "flowise":
                return FlowiseService(config)
            elif provider == "n8n":
                return N8NService(config)
            elif provider == "dify":
                return DifyService(config)
            elif provider == "openai":
                return OpenAIService(config)
            elif provider == "typebot":
                return TypebotService(config)
            else:
                raise ValueError(f"Unknown provider: {provider}")
        except Exception as e:
            logger.error(f"Error creating provider service for {provider}: {e}")
            raise

    async def _run_async_impl(
        self, ctx: InvocationContext
    ) -> AsyncGenerator[Event, None]:
        """
        Implementation of the External agent.

        This method sends the user's message to the external provider
        and returns the response as events.
        """
        try:
            # Extract the user's message from the context
            user_message = None

            # Search for the user's message in the session events
            if ctx.session and hasattr(ctx.session, "events") and ctx.session.events:
                for event in reversed(ctx.session.events):
                    if event.author == "user" and event.content and event.content.parts:
                        user_message = event.content.parts[0].text
                        break

            # Check in the session state if the message was not found in the events
            if not user_message and ctx.session and ctx.session.state:
                if "user_message" in ctx.session.state:
                    user_message = ctx.session.state["user_message"]
                elif "message" in ctx.session.state:
                    user_message = ctx.session.state["message"]

            if not user_message:
                user_message = "[media]"

            import json as _json
            logger.info("SESSION STATE: " + _json.dumps(dict(ctx.session.state), default=str)[:1000])
            # Get session ID from context
            session_id = self._get_session_id(ctx)

            # Build context for provider
            provider_context = self._build_provider_context(ctx, session_id)

            # Send message to provider
            try:
                response_text = await self.provider_service.send_message(
                    message=user_message,
                    session_id=session_id,
                    context=provider_context,
                )

                # Yield response event
                yield Event(
                    author=self.name,
                    content=Content(
                        role="agent",
                        parts=[Part(text=response_text)],
                    ),
                )

                # Execute sub-agents if any
                for sub_agent in self.sub_agents:
                    async for event in sub_agent.run_async(ctx):
                        yield event

            except Exception as e:
                logger.error(f"Error calling provider {self.provider}: {e}")
                yield Event(
                    author=f"{self.name}-error",
                    content=Content(
                        role="agent",
                        parts=[Part(text=f"Error calling {self.provider}: {str(e)}")],
                    ),
                )

        except Exception as e:
            logger.error(f"Error in ExternalAgent._run_async_impl: {e}")
            yield Event(
                author=f"{self.name}-error",
                content=Content(
                    role="agent",
                    parts=[Part(text=f"Error processing external agent: {str(e)}")],
                ),
            )

    def _get_session_id(self, ctx: InvocationContext) -> str:
        """Get or generate session ID from context."""
        # Use the actual ADK session ID first
        if ctx.session and ctx.session.id:
            return ctx.session.id
        if ctx.session and ctx.session.state:
            session_id = ctx.session.state.get("session_id")
            if session_id:
                return session_id
        import uuid
        return str(uuid.uuid4())

    def _build_provider_context(self, ctx: InvocationContext, session_id: str) -> Dict[str, Any]:
        """Build context dictionary for provider."""
        context: Dict[str, Any] = {
            "sessionId": session_id,
        }

        state = ctx.session.state if ctx.session and ctx.session.state else {}
        crm_data = state.get("evoai_crm_data", {}) or {}
        contact = state.get("contact", {}) or crm_data.get("contact", {}) or {}
        inbox = crm_data.get("inbox", {}) or {}
        phone = contact.get("phone_number", "") or ""
        remote_jid = state.get("remoteJid", "") or (
            phone.replace("+", "").replace(" ", "") + "@s.whatsapp.net" if phone else ""
        )

        # Fetch last message id and timestamp from CRM
        _msg_id = ""
        _msg_ts = ""
        try:
            import httpx as _httpx, os as _os
            _crm_url = _os.getenv("EVO_AI_CRM_URL", "http://evocrm_crm:3000")
            _api_token = "ad861676c2618b5d3243940355efcaa3e2040d285ddbf3dd1b0447fee59023c3"
            _disp_id = (crm_data.get("conversation", {}) or {}).get("display_id", "")
            if _disp_id:
                _r = _httpx.get(
                    f"{_crm_url}/api/v1/conversations/{_disp_id}/messages",
                    headers={"api_access_token": _api_token},
                    timeout=5.0
                )
                _msgs = _r.json().get("data", [])
                if _msgs:
                    _last = _msgs[-1]
                    _msg_id = str(_last.get("id", ""))
                    _msg_ts = str(_last.get("created_at", ""))
        except Exception as _e:
            logger.warning(f"Could not fetch message metadata: {_e}")

        # Fetch all messages for the conversation
        _messages = []
        try:
            import httpx as _httpx2, os as _os2
            _crm_url2 = _os2.getenv("EVO_AI_CRM_URL", "http://evocrm_crm:3000")
            _api_token2 = "ad861676c2618b5d3243940355efcaa3e2040d285ddbf3dd1b0447fee59023c3"
            _disp_id2 = (crm_data.get("conversation", {}) or {}).get("display_id", "")
            # Fetch debounce_time from agent bot config to use as time window
            _debounce_time = 7  # default fallback
            _agent_bot_id = state.get("agent_bot_id", "")
            if _agent_bot_id:
                try:
                    _rb = _httpx2.get(
                        f"{_crm_url2}/api/v1/agent_bots/{_agent_bot_id}",
                        headers={"api_access_token": _api_token2},
                        timeout=5.0
                    )
                    _debounce_time = int(_rb.json().get("data", {}).get("debounce_time", 7))
                except Exception:
                    pass
            _burst_window = _debounce_time + 5  # debounce + 5s safety buffer
            if _disp_id2:
                _r2 = _httpx2.get(
                    f"{_crm_url2}/api/v1/conversations/{_disp_id2}/messages",
                    headers={"api_access_token": _api_token2},
                    timeout=5.0
                )
                _raw_msgs = _r2.json().get("data", []) if isinstance(_r2.json(), dict) else _r2.json()
                # Include only incoming messages within the debounce burst window
                _incoming_msgs = [
                    _m for _m in _raw_msgs
                    if _m.get("message_type") == "incoming"
                ]
                if _incoming_msgs:
                    _latest_ts = max(_m.get("created_at", 0) for _m in _incoming_msgs)
                    _current_turn = [
                        _m for _m in _incoming_msgs
                        if _latest_ts - _m.get("created_at", 0) <= _burst_window
                    ]
                else:
                    _current_turn = []
                for _m in _current_turn:
                    _messages.append({
                        "id": _m.get("id", ""),
                        "content": _m.get("content") or "",
                        "created_at": _m.get("created_at", 0),
                        "attachments": [
                            {
                                "id": _a.get("id", ""),
                                "data_url": _a.get("data_url", ""),
                                "extension": _a.get("extension") or "",
                                "file_size": _a.get("file_size", 0),
                                "file_type": _a.get("file_type", "file"),
                            }
                            for _a in _m.get("attachments", [])
                        ],
                        "content_type": _m.get("content_type") or "text",
                    })
        except Exception as _e2:
            logger.warning(f"Could not fetch messages: {_e2}")

        context.update({
            "remoteJid": remote_jid,
            "pushName": state.get("pushName", "") or contact.get("name", ""),
            "instanceName": state.get("instanceName", "") or inbox.get("name", ""),
            "serverUrl": "",
            "apiKey": "",
            "messageId": "",
            "timestamp": "",
            "conversationId": str((crm_data.get("conversation", {}) or {}).get("id", "") or crm_data.get("conversation_id", "")),
            "messages": _messages,
        })

        return context


