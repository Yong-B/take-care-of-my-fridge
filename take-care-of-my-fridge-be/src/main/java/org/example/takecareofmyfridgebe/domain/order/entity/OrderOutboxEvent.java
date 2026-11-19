package org.example.takecareofmyfridgebe.domain.order.entity;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Index;
import jakarta.persistence.Table;
import java.time.LocalDateTime;
import lombok.AccessLevel;
import lombok.Builder;
import lombok.Getter;
import lombok.NoArgsConstructor;
import org.example.takecareofmyfridgebe.global.entity.BaseTimeEntity;

// 구매 확정과 같은 트랜잭션에서 저장하는 보낼 이벤트. 발행 스케줄러가 대기 건을 오래된 순으로 읽어 Kafka로 보낸다.
@Entity
@Table(
    name = "order_outbox_events",
    indexes = {
        @Index(name = "idx_order_outbox_events_status_id", columnList = "status, id")
    }
)
@Getter
@NoArgsConstructor(access = AccessLevel.PROTECTED)
public class OrderOutboxEvent extends BaseTimeEntity {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    @Column(name = "id", nullable = false)
    private Long id;

    @Column(name = "topic", nullable = false, length = 100)
    private String topic;

    // Kafka 메시지 키(주문 ID). 같은 주문의 이벤트가 같은 파티션으로 가게 한다.
    @Column(name = "message_key", nullable = false, length = 100)
    private String messageKey;

    // 이벤트 JSON. 발행할 때 원래 이벤트 record로 되돌려 보낸다(문자열 그대로 보내면 받는 쪽 형식이 깨진다).
    @Column(name = "payload", nullable = false, columnDefinition = "json")
    private String payload;

    @Enumerated(EnumType.STRING)
    @Column(name = "status", nullable = false)
    private OutboxStatus status;

    @Column(name = "attempt_count", nullable = false)
    private int attemptCount;

    // Kafka 수신 확인 시각 (완료 전에는 null).
    @Column(name = "published_at")
    private LocalDateTime publishedAt;

    @Builder
    private OrderOutboxEvent(String topic, String messageKey, String payload) {
        this.topic = topic;
        this.messageKey = messageKey;
        this.payload = payload;
        this.status = OutboxStatus.PENDING;
        this.attemptCount = 0;
    }

    // Kafka가 받았다고 응답한 뒤에만 부른다. 보내기만 하고 바꾸면 응답 전에 실패한 이벤트가 사라진다.
    public void markPublished(LocalDateTime publishedAt) {
        this.status = OutboxStatus.PUBLISHED;
        this.publishedAt = publishedAt;
    }

    // 이 이벤트만의 문제로 실패했을 때 부른다(Kafka에 닿지 못한 실패는 세지 않는다).
    // 실패 횟수만 올려 다음 주기에 다시 보낸다. 상한에 닿으면 더 보내지 않고 실패로 남겨 따로 확인한다.
    public void recordFailure(int maxAttempts) {
        this.attemptCount++;
        if (attemptCount >= maxAttempts) {
            this.status = OutboxStatus.FAILED;
        }
    }
}
