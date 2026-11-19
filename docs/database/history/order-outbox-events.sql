-- 냉장고를 부탁해 · 구매 확정 이벤트 outbox (order_outbox_events)
-- 구매 확정과 같은 트랜잭션에서 보낼 이벤트를 먼저 저장하고, 발행 스케줄러가 Kafka로 보낸다.
-- 확정이 커밋되면 이벤트도 함께 남고, 롤백되면 함께 사라진다. 커밋 뒤 발행이 실패해도 대기 상태로 남아 다시 보낸다.
-- 주문 ID는 Kafka 메시지 키로만 쓰므로 물리 FK를 걸지 않는다.
-- 실행: 각 DB에 한 번. 앱을 새 코드로 띄우기 전에 실행한다(ddl-auto=validate 환경 대비).

CREATE TABLE IF NOT EXISTS order_outbox_events (
    id            BIGINT       NOT NULL AUTO_INCREMENT                    COMMENT 'outbox 이벤트 ID (클수록 나중에 저장)',
    topic         VARCHAR(100) NOT NULL                                   COMMENT '보낼 Kafka 토픽 (예: purchase-confirmed)',
    message_key   VARCHAR(100) NOT NULL                                   COMMENT 'Kafka 메시지 키 (주문 ID)',
    payload       JSON         NOT NULL                                   COMMENT '이벤트 내용 (발행 때 원래 이벤트 형태로 되돌려 보냄)',
    status        ENUM('PENDING', 'PUBLISHED', 'FAILED') NOT NULL DEFAULT 'PENDING' COMMENT '발행 상태 (대기/완료/실패. 실패는 시도 상한을 넘어 따로 확인할 건)',
    attempt_count INT          NOT NULL DEFAULT 0                         COMMENT '이벤트 자체 문제로 발행에 실패한 횟수 (Kafka 연결 실패는 세지 않음, 상한에 닿으면 FAILED)',
    published_at  DATETIME(6)  NULL                                       COMMENT 'Kafka 수신 확인 시각 (완료 전에는 NULL)',
    created_at    DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6)      COMMENT '생성일시 (구매 확정과 같은 트랜잭션에서 저장한 시각)',
    updated_at    DATETIME(6)  NOT NULL DEFAULT CURRENT_TIMESTAMP(6) ON UPDATE CURRENT_TIMESTAMP(6) COMMENT '수정일시',
    PRIMARY KEY (id),
    KEY idx_order_outbox_events_status_id (status, id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci COMMENT='구매 확정 이벤트 outbox (주문 변경과 같은 트랜잭션에서 저장, 스케줄러가 발행)';

-- 확인: 테이블과 인덱스
SHOW CREATE TABLE order_outbox_events;
