# Verification Policy — Next Iterations

> 이 문서는 feature/verification-policy 브랜치에서 scope out된 항목의 추후 계획입니다.
> P0-P2 (governance + 템플릿) 완료 후, 다음 단계로 진행할 항목들입니다.

---

## --with-self-verification 플래그 (설계 미확정)

Worker/Verifier의 행위 이력을 구조화된 JSON으로 기록하는 신규 기능.

### 개념
- `--debug`와 별도 플래그
- Worker: 무엇을 했는지, 어떤 파일을 변경했는지, 어떤 테스트를 실행했는지 기록
- Verifier: 어떤 명령을 실행했는지, 어떤 근거로 판정했는지 기록

### 용도
1. **같은 iteration**: Verifier가 Worker 행위 이력을 교차 검증
2. **cross-iteration (meta-loop)**: 완료 후 report 분석 → PRD/test-spec 보강 → 재실행

### 미결 설계 사항
- [ ] 출력 형식: JSON vs Markdown
- [ ] 파일 위치: `logs/<slug>/self-verification-report-NNN.json`?
- [ ] 기록 주체: Worker/Verifier 각각 기록 vs Leader가 조합
- [ ] Meta-loop 분석 도구: Leader? 별도 Agent?

---

## P3: 외부 도구 연동 + 도메인 특화

P0-P2 (governance 정책 + 템플릿)가 기반. P3는 외부 의존성이 있어 별도 feature branch에서 진행.

### P3-1: Domain Rule Packs
- **목적**: 도메인별(금융, 의료, 보안) 검증 규칙셋
- **별도 분리 사유**: 범용 governance와 성격이 다름. 플러그인 구조 설계 필요.
- [ ] 플러그인 로딩 메커니즘 설계
- [ ] 금융 도메인 규칙 팩 (첫 번째)
- [ ] 규칙 팩 작성 가이드

### P3-2: Playwright Agents
- **목적**: visual/content task type의 자동 검증 (스크린샷 비교, 접근성 체크)
- **별도 분리 사유**: Playwright 설치 + 브라우저 바이너리 + CI 환경 설정 필요.
- [ ] Playwright 연동 래퍼
- [ ] 스크린샷 비교 검증 로직
- [ ] CI 환경 가이드

### P3-3: Mutahunter / Spec Kit
- **목적**: CRITICAL risk의 mutation testing 자동 실행
- **별도 분리 사유**: 언어별 도구(mutmut, Stryker, go-mutesting) 래퍼 구현 필요. P0-8에서 Gate만 정의됨.
- [ ] 언어별 mutation tool 래퍼
- [ ] mutation score 자동 수집 + verdict 연동
- [ ] Spec Kit: test-spec 자동 생성 보조 도구
