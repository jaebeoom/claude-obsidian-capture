Runtime context의 KST date, Capture file path, Existing capture session ids를 기준으로 다음을 수행한다.

1. Claude in Chrome으로 claude.ai를 연다.
2. 시작 즉시 이번 실행 전용의 자동화 탭을 하나 만든다. 가능하면 `tabs_create_mcp`를 사용하고, 새로 만든 탭 id를 끝까지 기억한다.
3. 기존 사용자 탭이나 창을 재사용하지 않는다. 이미 열려 있던 사용자 탭이나 창은 읽기/닫기 대상에서 제외한다.
4. 이후 모든 탐색, 이동, 읽기, 평가 작업은 그 자동화 탭에서만 수행한다. 특정 프로젝트를 전제하지 말고, 계정 전체의 최근 대화 목록(홈, Recents, History, 검색 결과 포함)에서 KST date 기준 최근 24시간 이내 대화를 수집한다.
5. 특정 프로젝트가 비어 있거나 관련 대화가 없으면 거기서 머무르지 말고 최근 대화 목록 기준으로 계속 진행한다.
6. 각 대화를 평가한다.
   - Capture-worthy 포함: 투자 인사이트, 의사결정 근거, 새로운 프레임워크/관점, 장기적으로 재사용할 사고 흐름
   - 제외: 단순 Q&A, 코드 디버깅, 반복/일상 내용
7. Existing capture session ids에 이미 있는 세션은 후보에서 제외한다. 단, 최종 중복 검사는 로컬 스크립트가 다시 수행한다.
8. 적합한 세션은 요약하지 말고 대화 원문을 아래 후보 블록 포맷으로 stdout에만 출력한다.
9. 어떤 파일도 직접 읽거나 쓰지 않는다. Capture file path는 대상 경로 식별용으로만 사용한다.
10. PDF/책/웹 첨부자료 원문 전문은 Capture 후보에 복사하지 않는다. 그 자료를 놓고 Claude와 나눈 대화 원문만 저장한다.
11. source tag는 대화의 원천에 맞춘다.
   - Claude.ai 직접 대화 자체가 source이면 `#from/claude-ai`
   - PDF를 놓고 나눈 대화이면 `#from/pdf`
   - 책/독후감 대화이면 `#from/book`
   - 웹 리서치 대화이면 `#from/web`
12. 모든 후보 검토가 끝나면 자동화에 사용한 탭만 닫는다. 현재 런에서 직접 탭을 닫는 브라우저 도구가 노출돼 있으면 그것만 사용한다. 예: `tabs_close_mcp`. 그런 도구가 없으면 `computer`를 오직 해당 도구가 네이티브 탭 닫기 hotkey/shortcut action을 명시적으로 지원할 때만 사용한다. `shortcuts_list`, `shortcuts_execute`, `window.close()`, 페이지 레벨 JavaScript keyboard event는 탭 닫기 용도로 사용하지 않는다. 닫기를 시도했다면 `tabs_context_mcp`로 자동화 탭 id가 목록에서 사라졌는지 확인한다. 닫기 가능한 도구가 없거나 검증이 실패하면 그대로 중단하고 기존 사용자 탭/창은 건드리지 않는다. 이 종료 단계의 설명이나 실패 사유를 stdout에 출력하지 않는다.
13. Capture-worthy 후보가 없으면 정확히 `NO_CAPTURE_CANDIDATES`만 출력한다.

stdout에는 후보 블록 또는 `NO_CAPTURE_CANDIDATES` 외의 설명, 로그, 머리말, 꼬리말을 출력하지 않는다.

---

후보 블록 출력 포맷:

<!-- capture:item-start -->
## AI 세션 (HH:MM, claude.ai claude-opus-4-7)
<!-- source: claude.ai recent conversations -->
<!-- capture:session-id=claude.ai:CONVERSATION_ID -->

**나**: [사용자 발화 원문]

**AI**: [Claude 응답 원문]

#stage/capture #from/claude-ai
<!-- capture:item-end -->
