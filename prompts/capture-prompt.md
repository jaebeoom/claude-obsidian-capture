Runtime context의 KST date, Capture file path, Existing capture session ids를 기준으로 다음을 수행한다.

1. Claude in Chrome으로 claude.ai를 열고 "Obsidian Capture Source" 프로젝트로 이동한다.
2. KST date 기준 최근 24시간 이내 대화 목록을 수집한다.
3. 각 대화를 평가한다.
   - Capture-worthy 포함: 투자 인사이트, 의사결정 근거, 새로운 프레임워크/관점, 장기적으로 재사용할 사고 흐름
   - 제외: 단순 Q&A, 코드 디버깅, 반복/일상 내용
4. Existing capture session ids에 이미 있는 세션은 후보에서 제외한다. 단, 최종 중복 검사는 로컬 스크립트가 다시 수행한다.
5. 적합한 세션은 요약하지 말고 대화 원문을 아래 후보 블록 포맷으로 stdout에만 출력한다.
6. 어떤 파일도 직접 읽거나 쓰지 않는다. Capture file path는 대상 경로 식별용으로만 사용한다.
7. PDF/책/웹 첨부자료 원문 전문은 Capture 후보에 복사하지 않는다. 그 자료를 놓고 Claude와 나눈 대화 원문만 저장한다.
8. source tag는 대화의 원천에 맞춘다.
   - Claude.ai 직접 대화 자체가 source이면 `#from/claude-ai`
   - PDF를 놓고 나눈 대화이면 `#from/pdf`
   - 책/독후감 대화이면 `#from/book`
   - 웹 리서치 대화이면 `#from/web`
9. Capture-worthy 후보가 없으면 정확히 `NO_CAPTURE_CANDIDATES`만 출력한다.

stdout에는 후보 블록 또는 `NO_CAPTURE_CANDIDATES` 외의 설명, 로그, 머리말, 꼬리말을 출력하지 않는다.

---

후보 블록 출력 포맷:

<!-- capture:item-start -->
## AI 세션 (HH:MM, claude.ai claude-opus-4-7)
<!-- source: claude.ai Obsidian Capture Source -->
<!-- capture:session-id=claude.ai:CONVERSATION_ID -->

**나**: [사용자 발화 원문]

**AI**: [Claude 응답 원문]

#stage/capture #from/claude-ai
<!-- capture:item-end -->
