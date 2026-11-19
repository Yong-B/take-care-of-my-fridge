package org.example.takecareofmyfridgebe.domain.order.entity;

import static org.assertj.core.api.Assertions.assertThat;

import java.time.LocalDateTime;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class OrderOutboxEventTest {

    @Test
    @DisplayName("새 outbox 이벤트는 대기 상태이고 실패 횟수 0, 발행 시각이 없다")
    void startsPending() {
        OrderOutboxEvent outbox = newOutbox();

        assertThat(outbox.getStatus()).isEqualTo(OutboxStatus.PENDING);
        assertThat(outbox.getAttemptCount()).isZero();
        assertThat(outbox.getPublishedAt()).isNull();
    }

    @Test
    @DisplayName("발행 완료로 표시하면 완료 상태가 되고 발행 시각이 남는다")
    void marksPublished() {
        OrderOutboxEvent outbox = newOutbox();
        LocalDateTime publishedAt = LocalDateTime.of(2026, 11, 19, 10, 0);

        outbox.markPublished(publishedAt);

        assertThat(outbox.getStatus()).isEqualTo(OutboxStatus.PUBLISHED);
        assertThat(outbox.getPublishedAt()).isEqualTo(publishedAt);
    }

    @Test
    @DisplayName("상한보다 적게 실패하면 실패 횟수만 오르고 대기 상태로 남는다")
    void staysPending_whenFailuresAreBelowLimit() {
        OrderOutboxEvent outbox = newOutbox();

        outbox.recordFailure(3);
        outbox.recordFailure(3);

        assertThat(outbox.getAttemptCount()).isEqualTo(2);
        assertThat(outbox.getStatus()).isEqualTo(OutboxStatus.PENDING);
    }

    @Test
    @DisplayName("실패 횟수가 상한에 닿으면 실패 상태가 된다")
    void becomesFailed_whenFailuresReachLimit() {
        OrderOutboxEvent outbox = newOutbox();

        outbox.recordFailure(3);
        outbox.recordFailure(3);
        outbox.recordFailure(3);

        assertThat(outbox.getAttemptCount()).isEqualTo(3);
        assertThat(outbox.getStatus()).isEqualTo(OutboxStatus.FAILED);
    }

    private OrderOutboxEvent newOutbox() {
        return OrderOutboxEvent.builder()
            .topic("purchase-confirmed")
            .messageKey("1")
            .payload("{}")
            .build();
    }
}
