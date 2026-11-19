package org.example.takecareofmyfridgebe.global.config.scheduling;

import org.springframework.boot.task.ThreadPoolTaskSchedulerBuilder;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.context.annotation.Primary;
import org.springframework.scheduling.annotation.EnableScheduling;
import org.springframework.scheduling.concurrent.ThreadPoolTaskScheduler;

@Configuration
@EnableScheduling
public class SchedulingConfig {

    // 구매 확정 outbox 발행만 도는 스케줄러 이름. @Scheduled(scheduler = ...)에 쓴다
    public static final String OUTBOX_RELAY_SCHEDULER = "outboxRelayTaskScheduler";

    // 기본 스케줄러. 다른 @Scheduled 작업과 SSE·push 구독이 쓴다.
    // TaskScheduler 빈을 하나라도 직접 만들면 Spring Boot가 기본 스케줄러를 만들지 않으므로, 같은 설정(spring.task.scheduling.*)으로 직접 만든다.
    @Bean
    @Primary
    public ThreadPoolTaskScheduler taskScheduler(ThreadPoolTaskSchedulerBuilder builder) {
        return builder.build();
    }

    // Kafka에 묶이는 outbox 발행을 다른 작업과 떼어 둔다. Kafka가 멈춰 발행이 오래 기다려도 기본 스케줄러의 작업은 밀리지 않는다.
    // 발행은 ShedLock으로 서버 전체에서 하나만 돌므로 스레드 하나면 된다.
    @Bean(name = OUTBOX_RELAY_SCHEDULER)
    public ThreadPoolTaskScheduler outboxRelayTaskScheduler() {
        ThreadPoolTaskScheduler scheduler = new ThreadPoolTaskScheduler();
        scheduler.setPoolSize(1);
        scheduler.setThreadNamePrefix("outbox-relay-");
        return scheduler;
    }
}
