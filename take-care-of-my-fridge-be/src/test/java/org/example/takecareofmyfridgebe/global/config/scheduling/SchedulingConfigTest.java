package org.example.takecareofmyfridgebe.global.config.scheduling;

import static org.assertj.core.api.Assertions.assertThat;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.springframework.boot.autoconfigure.AutoConfigurations;
import org.springframework.boot.autoconfigure.task.TaskSchedulingAutoConfiguration;
import org.springframework.boot.test.context.runner.ApplicationContextRunner;
import org.springframework.scheduling.TaskScheduler;
import org.springframework.scheduling.concurrent.ThreadPoolTaskScheduler;

// 발행 전용 스케줄러를 더해도 기본 스케줄러가 그대로 있고, TaskScheduler를 주입받는 곳(SSE·push 구독)은 기본 스케줄러를 받는지 확인한다
class SchedulingConfigTest {

    private final ApplicationContextRunner contextRunner = new ApplicationContextRunner()
        .withConfiguration(AutoConfigurations.of(TaskSchedulingAutoConfiguration.class))
        .withUserConfiguration(SchedulingConfig.class);

    @Test
    @DisplayName("TaskScheduler를 주입받으면 spring.task.scheduling 설정을 따르는 기본 스케줄러를 받는다")
    void injectsDefaultScheduler_whenTaskSchedulerIsRequested() {
        contextRunner
            .withPropertyValues("spring.task.scheduling.pool.size=3", "spring.task.scheduling.thread-name-prefix=test-scheduling-")
            .run(context -> {
                TaskScheduler injected = context.getBean(TaskScheduler.class);

                assertThat(injected).isSameAs(context.getBean("taskScheduler"));
                ThreadPoolTaskScheduler defaultScheduler = (ThreadPoolTaskScheduler) injected;
                assertThat(defaultScheduler.getScheduledThreadPoolExecutor().getCorePoolSize()).isEqualTo(3);
                assertThat(defaultScheduler.getThreadNamePrefix()).isEqualTo("test-scheduling-");
            });
    }

    @Test
    @DisplayName("outbox 발행 전용 스케줄러는 기본 스케줄러와 다른 스레드 하나짜리 스케줄러다")
    void createsSeparateSingleThreadSchedulerForOutboxRelay() {
        contextRunner.run(context -> {
            ThreadPoolTaskScheduler relay =
                context.getBean(SchedulingConfig.OUTBOX_RELAY_SCHEDULER, ThreadPoolTaskScheduler.class);

            assertThat(relay).isNotSameAs(context.getBean(TaskScheduler.class));
            assertThat(relay.getScheduledThreadPoolExecutor().getCorePoolSize()).isEqualTo(1);
            assertThat(relay.getThreadNamePrefix()).isEqualTo("outbox-relay-");
        });
    }
}
