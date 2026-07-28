package io.github.densanken.mc.discordguildgate;

import java.util.UUID;

public final class DiscordGuildGateTest {

  private DiscordGuildGateTest() {}

  public static void main(String[] args) {
    UUID pending = UUID.fromString("f0de8848-19aa-4043-af94-bfbe429a1eb8");
    UUID other = UUID.fromString("710de348-e591-4ca0-9fb6-0123456789ab");

    assertTrue(
      DiscordGuildGate.isNewSuccessfulLink(pending, null, pending),
      "a new link must be recognized"
    );
    assertFalse(
      DiscordGuildGate.isNewSuccessfulLink(pending, pending, pending),
      "an existing link must not be reported as newly completed"
    );
    assertFalse(
      DiscordGuildGate.isNewSuccessfulLink(pending, null, other),
      "a link to another account must not be reported as completed"
    );
    assertFalse(
      DiscordGuildGate.isNewSuccessfulLink(null, null, pending),
      "an unknown linking code must not be reported as completed"
    );

    assertEquals(
      25L,
      DiscordGuildGate.remainingRequestNanos(100L, 75L),
      "the shared request budget must return its remaining time"
    );
    assertEquals(
      0L,
      DiscordGuildGate.remainingRequestNanos(100L, 125L),
      "an exhausted request budget must not become negative"
    );
    assertEquals(
      "Steve (discord-name)",
      DiscordGuildGate.linkedDisplayName("Steve", "discord-name"),
      "Discord to Minecraft names must use the documented order"
    );
    assertEquals(
      "discord-name（Steve）",
      DiscordGuildGate.webhookDisplayName("discord-name", "Steve"),
      "webhook names must use the documented order"
    );
    assertEquals(
      "https://cdn.discordapp.com/guild-avatar.png",
      DiscordGuildGate.webhookAvatarUrl(
        "https://cdn.discordapp.com/guild-avatar.png",
        "https://crafthead.net/helm/minecraft-uuid"
      ),
      "Discord profile avatars must be preferred for linked users"
    );
    assertEquals(
      "https://crafthead.net/helm/minecraft-uuid",
      DiscordGuildGate.webhookAvatarUrl(
        null,
        "https://crafthead.net/helm/minecraft-uuid"
      ),
      "Minecraft avatars must be used when a Discord profile is unavailable"
    );

    assertTrue(
      DiscordGuildGate.shouldSuppressSystemMessage(true, false),
      "vanished players must not produce system messages"
    );
    assertTrue(
      DiscordGuildGate.shouldSuppressSystemMessage(false, true),
      "silent join or quit permission must suppress system messages"
    );
    assertFalse(
      DiscordGuildGate.shouldSuppressSystemMessage(false, false),
      "ordinary joins and quits must produce system messages"
    );

  }

  private static void assertTrue(boolean actual, String message) {
    if (!actual) {
      throw new AssertionError(message);
    }
  }

  private static void assertFalse(boolean actual, String message) {
    assertTrue(!actual, message);
  }

  private static void assertEquals(
    Object expected,
    Object actual,
    String message
  ) {
    if (!expected.equals(actual)) {
      throw new AssertionError(
        message + ": expected=" + expected + ", actual=" + actual
      );
    }
  }
}
