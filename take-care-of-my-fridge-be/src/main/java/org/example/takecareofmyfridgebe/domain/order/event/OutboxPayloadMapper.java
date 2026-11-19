package org.example.takecareofmyfridgebe.domain.order.event;

import lombok.AccessLevel;
import lombok.NoArgsConstructor;
import tools.jackson.databind.cfg.DateTimeFeature;
import tools.jackson.databind.json.JsonMapper;

// outbox에 이벤트를 JSON으로 저장하고, 발행할 때 원래 이벤트 record로 되돌린다.
// 저장한 문자열을 그대로 보내면 Kafka 직렬화가 문자열을 한 번 더 감싸 받는 쪽 형식이 깨지므로 꼭 record로 되돌려 보낸다.
// 날짜는 Kafka 발행 설정(KafkaConfig)과 같이 ISO 문자열로 쓴다.
@NoArgsConstructor(access = AccessLevel.PRIVATE)
public final class OutboxPayloadMapper {

    private static final JsonMapper JSON = JsonMapper.builder()
            .disable(DateTimeFeature.WRITE_DATES_AS_TIMESTAMPS)
            .build();

    public static String write(Object event) {
        return JSON.writeValueAsString(event);
    }

    public static <T> T read(String payload, Class<T> type) {
        return JSON.readValue(payload, type);
    }
}
