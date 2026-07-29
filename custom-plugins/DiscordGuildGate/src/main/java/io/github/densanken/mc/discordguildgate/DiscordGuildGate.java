package io.github.densanken.mc.discordguildgate;

import github.scarsz.discordsrv.DiscordSRV;
import github.scarsz.discordsrv.api.Subscribe;
import github.scarsz.discordsrv.api.commands.SlashCommand;
import github.scarsz.discordsrv.api.commands.PluginSlashCommand;
import github.scarsz.discordsrv.api.commands.SlashCommandProvider;
import github.scarsz.discordsrv.api.events.AccountLinkedEvent;
import github.scarsz.discordsrv.api.events.AccountUnlinkedEvent;
import github.scarsz.discordsrv.api.events.AchievementMessagePostProcessEvent;
import github.scarsz.discordsrv.api.events.AchievementMessagePreProcessEvent;
import github.scarsz.discordsrv.api.events.DeathMessagePostProcessEvent;
import github.scarsz.discordsrv.api.events.DiscordGuildMessagePostProcessEvent;
import github.scarsz.discordsrv.api.events.GameChatMessagePostProcessEvent;
import github.scarsz.discordsrv.dependencies.jda.api.EmbedBuilder;
import github.scarsz.discordsrv.dependencies.jda.api.MessageBuilder;
import github.scarsz.discordsrv.dependencies.jda.api.Permission;
import github.scarsz.discordsrv.dependencies.jda.api.entities.Guild;
import github.scarsz.discordsrv.dependencies.jda.api.entities.Member;
import github.scarsz.discordsrv.dependencies.jda.api.entities.MessageEmbed;
import github.scarsz.discordsrv.dependencies.jda.api.entities.TextChannel;
import github.scarsz.discordsrv.dependencies.jda.api.exceptions.ErrorResponseException;
import github.scarsz.discordsrv.dependencies.jda.api.events.interaction.SlashCommandEvent;
import github.scarsz.discordsrv.dependencies.jda.api.interactions.InteractionHook;
import github.scarsz.discordsrv.dependencies.jda.api.interactions.commands.OptionMapping;
import github.scarsz.discordsrv.dependencies.jda.api.interactions.commands.OptionType;
import github.scarsz.discordsrv.dependencies.jda.api.interactions.commands.build.CommandData;
import github.scarsz.discordsrv.dependencies.jda.api.requests.ErrorResponse;
import github.scarsz.discordsrv.util.WebhookUtil;
import github.scarsz.discordsrv.util.PlayerUtil;
import github.scarsz.discordsrv.util.SchedulerUtil;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Collection;
import java.util.Collections;
import java.util.LinkedHashSet;
import java.util.Properties;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;
import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.NamedTextColor;
import net.kyori.adventure.text.serializer.legacy.LegacyComponentSerializer;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.player.AsyncPlayerPreLoginEvent;
import org.bukkit.event.player.PlayerAdvancementDoneEvent;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.event.player.PlayerQuitEvent;
import org.bukkit.plugin.java.JavaPlugin;

/**
 * DiscordSRV の複数 guild ID 指定は全 guild への所属を要求する
 * この plugin は linked account が許可リストのいずれか一つに所属することを確認する
 */
public final class DiscordGuildGate extends JavaPlugin implements Listener, SlashCommandProvider {

  private static final String GUILD_ID_PATTERN = "[0-9]{17,20}";
  private static final String LINK_CODE_PATTERN = "[0-9]{4}";
  private static final String ADVANCEMENT_TRANSLATIONS_RESOURCE =
    "advancements-ja_jp.properties";
  private static final int MAX_ALLOWED_GUILDS = 10;
  private static final String DEFAULT_NOT_ALLOWED_MESSAGE =
    "&c参加するには、許可された Discord サーバーへの参加が必要です";
  private static final String DEFAULT_VERIFICATION_FAILED_MESSAGE =
    "&cDiscord サーバーへの参加状況を確認できませんでした。しばらくしてから再試行してください";
  private static final int DEFAULT_CACHE_SECONDS = 30;
  private static final int DEFAULT_REQUEST_TIMEOUT_SECONDS = 5;
  private static final long PENDING_NAME_TTL_NANOS = TimeUnit.MINUTES.toNanos(
    10
  );
  private static final int MAX_PENDING_MINECRAFT_NAMES = 2_048;
  private static final long SYSTEM_WEBHOOK_RETRY_TICKS = 100;
  private static final String[] REQUIRED_PLUGINS = {
    "CoreProtect",
    "DiscordGuildGate",
    "DiscordSRV",
    "Maintenance",
    "TabTPS",
    "ViaVersion",
    "voicechat",
  };

  private Set<String> allowedGuildIds = Set.of();
  private final ConcurrentHashMap<
    String,
    MembershipCacheEntry
  > membershipCache = new ConcurrentHashMap<>();
  private final ConcurrentHashMap<UUID, MinecraftNameCacheEntry> pendingMinecraftNames =
    new ConcurrentHashMap<>();
  private final ConcurrentHashMap<UUID, String> linkedMinecraftNames =
    new ConcurrentHashMap<>();
  private final ConcurrentHashMap<GuildMemberKey, DiscordProfileCacheEntry> discordProfiles =
    new ConcurrentHashMap<>();
  private Component notAllowedMessage;
  private Component verificationFailedMessage;
  private long membershipCacheNanos;
  private int requestTimeoutSeconds;
  private final Properties advancementTranslations = new Properties();

  @Override
  public void onEnable() {
    Set<String> configuredGuildIds = new LinkedHashSet<>();
    for (String guildId : getConfig().getStringList("allowed-guild-ids")) {
      String trimmedGuildId = guildId.trim();
      if (trimmedGuildId.matches(GUILD_ID_PATTERN)) {
        configuredGuildIds.add(trimmedGuildId);
      } else {
        getLogger().warning(
          "Ignoring invalid Discord guild ID in config: " + guildId
        );
      }
    }
    if (configuredGuildIds.size() > MAX_ALLOWED_GUILDS) {
      getLogger().severe(
        "allowed-guild-ids は最大 " +
          MAX_ALLOWED_GUILDS +
          " 件まで指定できます。設定が完了するまで、すべてのログインを拒否します。"
      );
      configuredGuildIds.clear();
    }
    allowedGuildIds = Collections.unmodifiableSet(configuredGuildIds);
    notAllowedMessage = message(
      "not-allowed-message",
      DEFAULT_NOT_ALLOWED_MESSAGE
    );
    verificationFailedMessage = message(
      "verification-failed-message",
      DEFAULT_VERIFICATION_FAILED_MESSAGE
    );
    membershipCacheNanos = TimeUnit.SECONDS.toNanos(
      positiveConfigInt("membership-cache-seconds", DEFAULT_CACHE_SECONDS)
    );
    requestTimeoutSeconds = positiveConfigInt(
      "discord-request-timeout-seconds",
      DEFAULT_REQUEST_TIMEOUT_SECONDS
    );
    loadAdvancementTranslations();
    loadLinkedMinecraftNames();

    if (allowedGuildIds.isEmpty()) {
      getLogger().severe(
        "allowed-guild-ids が空です。設定が完了するまで、すべてのログインを拒否します。"
      );
    }

    getServer().getPluginManager().registerEvents(this, this);
    DiscordSRV.api.subscribe(this);
    SchedulerUtil.runTaskTimerAsynchronously(
      this,
      this::purgeExpiredCaches,
      20L * 60L,
      20L * 60L
    );
  }

  @Override
  public void onDisable() {
    membershipCache.clear();
    pendingMinecraftNames.clear();
    linkedMinecraftNames.clear();
    discordProfiles.clear();
    DiscordSRV.api.unsubscribe(this);
  }

  @Subscribe
  public void onAccountLinked(AccountLinkedEvent event) {
    UUID minecraftUuid = event.getPlayer().getUniqueId();
    String minecraftName = pendingMinecraftName(minecraftUuid);
    if (minecraftName == null) {
      minecraftName = event.getPlayer().getName();
    }
    rememberLinkedMinecraftName(minecraftUuid, minecraftName);
  }

  @Subscribe
  public void onAccountUnlinked(AccountUnlinkedEvent event) {
    linkedMinecraftNames.remove(event.getPlayer().getUniqueId());
  }

  @Subscribe
  public void onAchievementMessagePreProcess(
    AchievementMessagePreProcessEvent event
  ) {
    if (
      !(event.getTriggeringBukkitEvent() instanceof PlayerAdvancementDoneEvent advancementEvent)
    ) {
      return;
    }
    String translatedTitle = advancementTranslation(
      advancementEvent,
      "title"
    );
    if (translatedTitle != null && !translatedTitle.isBlank()) {
      event.setAchievementName(translatedTitle);
    }
  }

  @Subscribe
  public void onDiscordGuildMessagePostProcess(
    DiscordGuildMessagePostProcessEvent event
  ) {
    UUID minecraftUuid = DiscordSRV.getPlugin()
      .getAccountLinkManager()
      .getUuid(event.getAuthor().getId());
    if (minecraftUuid == null) {
      return;
    }
    String minecraftName = minecraftName(minecraftUuid);
    if (minecraftName == null || minecraftName.isBlank()) {
      return;
    }
    String discordName = event.getMember() == null
      ? event.getAuthor().getName()
      : event.getMember().getEffectiveName();
    String linkedDisplayName = linkedDisplayName(minecraftName, discordName);
    event.setMinecraftMessage(
      event
        .getMinecraftMessage()
        .replaceText(builder ->
          builder
            .matchLiteral(discordName)
            .replacement(linkedDisplayName)
            .once()
        )
    );
  }

  @Subscribe
  public void onGameChatMessagePostProcess(
    GameChatMessagePostProcessEvent event
  ) {
    if (event.isCancelled()) {
      return;
    }
    TextChannel channel = destinationChannel(event.getChannel());
    if (channel == null) {
      return;
    }
    if (!canDeliverWebhook(channel)) {
      return;
    }
    event.setCancelled(true);
    PlayerIdentity player = playerIdentity(event.getPlayer());
    String processedMessage = event.getProcessedMessage();
    SchedulerUtil.runTaskAsynchronously(
      this,
      () -> {
        WebhookIdentity webhookIdentity = webhookIdentity(player, channel);
        deliverWebhook(
          channel,
          webhookIdentity.name(),
          webhookIdentity.avatarUrl(),
          processedMessage,
          Collections.emptyList()
        );
      }
    );
  }

  @Subscribe
  public void onAchievementMessagePostProcess(
    AchievementMessagePostProcessEvent event
  ) {
    if (!event.isUsingWebhooks()) {
      return;
    }
    TextChannel channel = destinationChannel(event.getChannel());
    if (channel != null) {
      PlayerIdentity player = playerIdentity(event.getPlayer());
      WebhookIdentity webhookIdentity = webhookIdentity(player, channel);
      event.setWebhookName(webhookIdentity.name());
      event.setWebhookAvatarUrl(webhookIdentity.avatarUrl());
      String description = null;
      if (
        event.getTriggeringBukkitEvent() instanceof PlayerAdvancementDoneEvent advancementEvent
      ) {
        description = advancementTranslation(advancementEvent, "description");
      }
      EmbedBuilder embed = systemEmbed(
        "進捗「" + event.getAchievementName() + "」を達成しました",
        0xF1C40F
      );
      if (description != null && !description.isBlank()) {
        embed.setDescription(description);
      }
      event.setDiscordMessage(new MessageBuilder(embed).build());
    }
  }

  @Subscribe
  public void onDeathMessagePostProcess(DeathMessagePostProcessEvent event) {
    if (!event.isUsingWebhooks()) {
      return;
    }
    TextChannel channel = destinationChannel(event.getChannel());
    if (channel != null) {
      PlayerIdentity player = playerIdentity(event.getPlayer());
      WebhookIdentity webhookIdentity = webhookIdentity(player, channel);
      event.setWebhookName(webhookIdentity.name());
      event.setWebhookAvatarUrl(webhookIdentity.avatarUrl());
      event.setDiscordMessage(
        new MessageBuilder(
          systemEmbed("死亡しました", 0xED4245).setDescription(
            event.getDeathMessage()
          )
        ).build()
      );
    }
  }

  @EventHandler(priority = EventPriority.MONITOR)
  public void onPlayerJoin(PlayerJoinEvent event) {
    Player player = event.getPlayer();
    rememberLinkedMinecraftName(player);
    if (suppressSystemMessage(player, "discordsrv.silentjoin")) {
      return;
    }
    sendSystemWebhookAsync(
      playerIdentity(player),
      event.getPlayer().hasPlayedBefore()
        ? "サーバーに参加しました"
        : "初めてサーバーに参加しました",
      0x57F287
    );
  }

  @EventHandler(priority = EventPriority.MONITOR)
  public void onPlayerQuit(PlayerQuitEvent event) {
    Player player = event.getPlayer();
    if (suppressSystemMessage(player, "discordsrv.silentquit")) {
      return;
    }
    sendSystemWebhookAsync(
      playerIdentity(player),
      "サーバーから退出しました",
      0xED4245
    );
  }

  private boolean suppressSystemMessage(Player player, String permission) {
    return shouldSuppressSystemMessage(
      PlayerUtil.isVanished(player),
      player.hasPermission(permission)
    );
  }

  private void sendSystemWebhookAsync(
    PlayerIdentity player,
    String title,
    int color
  ) {
    SchedulerUtil.runTaskAsynchronously(
      this,
      () -> sendSystemWebhook(player, title, color, true)
    );
  }

  private void sendSystemWebhook(
    PlayerIdentity player,
    String title,
    int color,
    boolean retry
  ) {
    TextChannel channel = destinationChannel("global");
    if (channel == null) {
      if (retry) {
        SchedulerUtil.runTaskLaterAsynchronously(
          this,
          () -> sendSystemWebhook(player, title, color, false),
          SYSTEM_WEBHOOK_RETRY_TICKS
        );
      } else {
        getLogger().warning(
          "Could not deliver a system webhook because the global Discord channel is unavailable"
        );
      }
      return;
    }
    WebhookIdentity webhookIdentity = webhookIdentity(player, channel);
    deliverWebhook(
      channel,
      webhookIdentity.name(),
      webhookIdentity.avatarUrl(),
      "",
      Collections.singletonList(systemEmbed(title, color).build())
    );
  }

  private void deliverWebhook(
    TextChannel channel,
    String username,
    String avatarUrl,
    String content,
    Collection<? extends MessageEmbed> embeds
  ) {
    if (!canDeliverWebhook(channel)) {
      return;
    }
    try {
      WebhookUtil.deliverMessage(
        channel,
        username,
        avatarUrl,
        content,
        embeds
      );
    } catch (RuntimeException exception) {
      getLogger().warning(
        "Could not deliver a Discord webhook: " +
          exception.getClass().getSimpleName()
      );
    }
  }

  private boolean canDeliverWebhook(TextChannel channel) {
    if (
      channel
        .getGuild()
        .getSelfMember()
        .hasPermission(channel, Permission.MANAGE_WEBHOOKS)
    ) {
      return true;
    }
    getLogger().warning(
      "Could not deliver a Discord webhook because MANAGE_WEBHOOKS is missing for channel " +
        channel.getId()
    );
    return false;
  }

  private EmbedBuilder systemEmbed(String title, int color) {
    return new EmbedBuilder()
      .setTitle(title)
      .setColor(color)
      .setTimestamp(Instant.now());
  }

  private String advancementTranslation(
    PlayerAdvancementDoneEvent event,
    String field
  ) {
    if (!event.getAdvancement().getKey().getNamespace().equals("minecraft")) {
      return null;
    }
    String translationKey =
      "advancements." +
      event.getAdvancement().getKey().getKey().replace('/', '.') +
      "." +
      field;
    return advancementTranslations.getProperty(translationKey);
  }

  private TextChannel destinationChannel(String gameChannel) {
    if (!DiscordSRV.isReady) {
      return null;
    }
    String resolvedChannel = gameChannel;
    if (resolvedChannel == null || resolvedChannel.isBlank()) {
      resolvedChannel = DiscordSRV.getPlugin().getOptionalChannel("global");
    }
    if (resolvedChannel == null || resolvedChannel.isBlank()) {
      return null;
    }
    return DiscordSRV.getPlugin()
      .getDestinationTextChannelForGameChannelName(resolvedChannel);
  }

  private WebhookIdentity webhookIdentity(
    PlayerIdentity player,
    TextChannel channel
  ) {
    String minecraftAvatarUrl = minecraftAvatarUrl(player);
    String discordId = DiscordSRV.getPlugin()
      .getAccountLinkManager()
      .getDiscordId(player.uuid());
    if (discordId == null) {
      return new WebhookIdentity(player.name(), minecraftAvatarUrl);
    }
    DiscordProfileCacheEntry discordProfile = discordProfile(
      channel.getGuild(),
      discordId
    );
    if (discordProfile == null) {
      return new WebhookIdentity(player.name(), minecraftAvatarUrl);
    }
    return new WebhookIdentity(
      webhookDisplayName(discordProfile.name(), player.name()),
      webhookAvatarUrl(discordProfile.avatarUrl(), minecraftAvatarUrl)
    );
  }

  private DiscordProfileCacheEntry discordProfile(
    Guild guild,
    String discordId
  ) {
    Member member = guild.getMemberById(discordId);
    if (member != null) {
      return cacheDiscordProfile(member);
    }

    GuildMemberKey cacheKey = new GuildMemberKey(guild.getId(), discordId);
    DiscordProfileCacheEntry cached = discordProfiles.get(cacheKey);
    if (cached != null && !cached.isExpired()) {
      return cached;
    }
    if (cached != null) {
      discordProfiles.remove(cacheKey, cached);
    }

    try {
      member = guild
        .retrieveMemberById(discordId)
        .timeout(requestTimeoutSeconds, TimeUnit.SECONDS)
        .complete();
      return member == null ? null : cacheDiscordProfile(member);
    } catch (ErrorResponseException exception) {
      if (exception.getErrorResponse() != ErrorResponse.UNKNOWN_MEMBER) {
        getLogger().warning(
          "Could not retrieve a Discord profile for guild " +
            guild.getId() +
            ": " +
            exception.getErrorResponse()
        );
      }
    } catch (RuntimeException exception) {
      getLogger().warning(
        "Could not retrieve a Discord profile for guild " +
          guild.getId() +
          ": " +
          exception.getClass().getSimpleName()
      );
    }
    return null;
  }

  private DiscordProfileCacheEntry cacheDiscordProfile(Member member) {
    DiscordProfileCacheEntry profile = new DiscordProfileCacheEntry(
      member.getEffectiveName(),
      member.getEffectiveAvatarUrl(),
      System.nanoTime() + membershipCacheNanos
    );
    discordProfiles.put(
      new GuildMemberKey(member.getGuild().getId(), member.getId()),
      profile
    );
    return profile;
  }

  private String minecraftAvatarUrl(PlayerIdentity player) {
    return DiscordSRV.getAvatarUrl(player.name(), player.uuid());
  }

  private void loadAdvancementTranslations() {
    try (
      InputStream input = getResource(ADVANCEMENT_TRANSLATIONS_RESOURCE)
    ) {
      if (input == null) {
        getLogger().warning(
          "Japanese advancement translations are unavailable"
        );
        return;
      }
      advancementTranslations.load(
        new InputStreamReader(input, StandardCharsets.UTF_8)
      );
    } catch (IOException exception) {
      getLogger().warning(
        "Could not load Japanese advancement translations: " +
          exception.getClass().getSimpleName()
      );
    }
  }

  private void loadLinkedMinecraftNames() {
    try {
      for (
        UUID minecraftUuid : DiscordSRV.getPlugin()
          .getAccountLinkManager()
          .getLinkedAccounts()
          .values()
      ) {
        rememberLinkedMinecraftName(
          minecraftUuid,
          getServer().getOfflinePlayer(minecraftUuid).getName()
        );
      }
    } catch (RuntimeException exception) {
      getLogger().warning(
        "Could not preload linked Minecraft names: " +
          exception.getClass().getSimpleName()
      );
    }
  }

  @Override
  public Set<PluginSlashCommand> getSlashCommands() {
    if (allowedGuildIds.isEmpty()) {
      return Set.of();
    }
    CommandData linkCommand = new CommandData(
      "link",
      "Minecraftアカウントを認証コードで連携します"
    ).addOption(
      OptionType.STRING,
      "code",
      "Minecraftへの接続時に表示された4桁の認証コード",
      true
    );
    return Set.of(
      new PluginSlashCommand(
        this,
        linkCommand,
        allowedGuildIds.toArray(String[]::new)
      )
    );
  }

  @SlashCommand(path = "link")
  public void handleLinkSlashCommand(SlashCommandEvent event) {
    if (
      !event.getName().equals("link") ||
      event.getGuild() == null ||
      !allowedGuildIds.contains(event.getGuild().getId())
    ) {
      return;
    }
    if (supportsInteractionHook(event)) {
      event
        .deferReply(true)
        .queue(
          hook -> editLinkResponse(hook, linkResponse(event)),
          exception -> getLogger().warning(
            "Could not defer the Discord link response: " +
              exception.getClass().getSimpleName()
          )
        );
      return;
    }
    // hook を使えない channel では 3 秒以内に応答する必要があるため、先に処理してから返信する
    replyLinkResponse(event, linkResponse(event));
  }

  /**
   * DiscordSRV 同梱の JDA は thread や voice channel の chat を channel として解決できない
   * この channel では InteractionHook 経由の応答が Message を組み立てられずに失敗するため、
   * deferred reply ではなく即時の reply で応答する
   */
  private boolean supportsInteractionHook(SlashCommandEvent event) {
    try {
      return event.getChannel() != null;
    } catch (RuntimeException exception) {
      return false;
    }
  }

  private String linkResponse(SlashCommandEvent event) {
    OptionMapping codeOption = event.getOption("code");
    if (
      codeOption == null ||
      !codeOption.getAsString().matches(LINK_CODE_PATTERN)
    ) {
      return "認証コードは4桁の数字で入力してください";
    }

    String code = codeOption.getAsString();
    UUID linkedBefore = DiscordSRV.getPlugin()
      .getAccountLinkManager()
      .getUuid(event.getUser().getId());
    UUID pendingMinecraftUuid = DiscordSRV.getPlugin()
      .getAccountLinkManager()
      .getLinkingCodes()
      .get(code);
    String response;
    boolean processFailed = false;
    try {
      response = DiscordSRV.getPlugin()
        .getAccountLinkManager()
        .process(code, event.getUser().getId());
    } catch (RuntimeException exception) {
      getLogger().warning(
        "Could not process a Discord account link: " +
          exception.getClass().getSimpleName()
      );
      response = "現在アカウントを連携できません。しばらくしてから再試行してください";
      processFailed = true;
    }
    if (response == null || response.isBlank()) {
      response = "認証コードを処理できませんでした。新しいコードで再試行してください";
    }
    UUID linkedAfter = DiscordSRV.getPlugin()
      .getAccountLinkManager()
      .getUuid(event.getUser().getId());
    if (
      !processFailed &&
      isNewSuccessfulLink(pendingMinecraftUuid, linkedBefore, linkedAfter)
    ) {
      String minecraftName = minecraftName(pendingMinecraftUuid);
      if (minecraftName != null) {
        response =
          "Minecraftアカウント（" +
          minecraftName +
          "）との連携が完了しました。Minecraftサーバーへ接続し直してください。";
      }
      pendingMinecraftNames.remove(pendingMinecraftUuid);
    }
    return response;
  }

  private void replyLinkResponse(SlashCommandEvent event, String response) {
    event
      .reply(response)
      .setEphemeral(true)
      .queue(
        ignored -> {},
        exception -> getLogger().warning(
          "Could not send the Discord link response: " +
            exception.getClass().getSimpleName()
        )
      );
  }

  private void editLinkResponse(InteractionHook hook, String response) {
    hook
      .editOriginal(response)
      .queue(
        ignored -> {},
        exception -> getLogger().warning(
          "Could not edit the Discord link response: " +
            exception.getClass().getSimpleName()
        )
      );
  }

  private String minecraftName(UUID minecraftUuid) {
    String linkedName = linkedMinecraftNames.get(minecraftUuid);
    if (linkedName != null && !linkedName.isBlank()) {
      return linkedName;
    }
    return pendingMinecraftName(minecraftUuid);
  }

  @Override
  public boolean onCommand(
    CommandSender sender,
    Command command,
    String label,
    String[] args
  ) {
    if (args.length != 1) {
      return false;
    }

    if (args[0].equalsIgnoreCase("plugins")) {
      sendPluginHealth(sender);
      return true;
    }
    if (!args[0].equalsIgnoreCase("status")) {
      return false;
    }

    String notReadyReason = readinessFailure();
    if (notReadyReason == null) {
      sender.sendMessage("READY allowed-guilds=" + allowedGuildIds.size());
    } else {
      sender.sendMessage("NOT_READY " + notReadyReason);
    }
    return true;
  }

  private void sendPluginHealth(CommandSender sender) {
    StringBuilder disabledPlugins = new StringBuilder();
    for (String pluginName : REQUIRED_PLUGINS) {
      if (getServer().getPluginManager().isPluginEnabled(pluginName)) {
        continue;
      }
      if (!disabledPlugins.isEmpty()) {
        disabledPlugins.append(',');
      }
      disabledPlugins.append(pluginName);
    }
    if (disabledPlugins.isEmpty()) {
      sender.sendMessage("ENABLED required-plugins=" + REQUIRED_PLUGINS.length);
    } else {
      sender.sendMessage("DISABLED required-plugins=" + disabledPlugins);
    }
  }

  @EventHandler(priority = EventPriority.HIGHEST)
  public void onAsyncPlayerPreLogin(AsyncPlayerPreLoginEvent event) {
    rememberPendingMinecraftName(event.getUniqueId(), event.getName());
    // DiscordSRV が Link-to-Join や ban で先に拒否した場合は、その理由を維持する
    if (event.getLoginResult() != AsyncPlayerPreLoginEvent.Result.ALLOWED) {
      return;
    }

    if (allowedGuildIds.isEmpty()) {
      event.disallow(
        AsyncPlayerPreLoginEvent.Result.KICK_OTHER,
        verificationFailedMessage
      );
      return;
    }

    if (!DiscordSRV.isReady) {
      event.disallow(
        AsyncPlayerPreLoginEvent.Result.KICK_OTHER,
        verificationFailedMessage
      );
      return;
    }

    String discordId;
    try {
      discordId = DiscordSRV.getPlugin()
        .getAccountLinkManager()
        .getDiscordIdBypassCache(event.getUniqueId());
    } catch (RuntimeException exception) {
      getLogger().warning(
        "Could not read a Discord account link: " +
          exception.getClass().getSimpleName()
      );
      event.disallow(
        AsyncPlayerPreLoginEvent.Result.KICK_OTHER,
        verificationFailedMessage
      );
      return;
    }

    if (discordId == null) {
      // 通常は DiscordSRV の Link-to-Join が link code を表示して先に拒否する
      event.disallow(
        AsyncPlayerPreLoginEvent.Result.KICK_WHITELIST,
        Component.text(
          "Discord アカウントを連携してから参加してください",
          NamedTextColor.RED
        )
      );
      return;
    }
    rememberLinkedMinecraftName(event.getUniqueId(), event.getName());

    MembershipCacheEntry cached = membershipCache.get(discordId);
    if (cached != null && !cached.isExpired()) {
      if (cached.allowed()) {
        return;
      }
      event.disallow(
        AsyncPlayerPreLoginEvent.Result.KICK_WHITELIST,
        notAllowedMessage
      );
      return;
    }
    if (cached != null) {
      membershipCache.remove(discordId, cached);
    }

    boolean verificationFailed = false;
    long requestDeadlineNanos =
      System.nanoTime() +
      TimeUnit.SECONDS.toNanos(requestTimeoutSeconds);
    for (String guildId : allowedGuildIds) {
      try {
        Guild guild = DiscordSRV.getPlugin().getJda().getGuildById(guildId);
        if (guild == null) {
          verificationFailed = true;
          getLogger().warning(
            "Configured guild is unavailable to the bot: " + guildId
          );
          continue;
        }

        Member member = guild.getMemberById(discordId);
        if (member == null) {
          long remainingNanos = remainingRequestNanos(
            requestDeadlineNanos,
            System.nanoTime()
          );
          if (remainingNanos == 0) {
            verificationFailed = true;
            getLogger().warning(
              "Discord membership verification exceeded its total timeout"
            );
            break;
          }
          member = guild
            .retrieveMemberById(discordId)
            .timeout(remainingNanos, TimeUnit.NANOSECONDS)
            .complete();
        }
        if (member != null) {
          cacheDiscordProfile(member);
          cacheMembership(discordId, true);
          return;
        }
      } catch (ErrorResponseException exception) {
        if (exception.getErrorResponse() == ErrorResponse.UNKNOWN_MEMBER) {
          continue;
        }
        verificationFailed = true;
        getLogger().warning(
          "Discord membership request failed for guild " +
            guildId +
            ": " +
            exception.getErrorResponse()
        );
      } catch (RuntimeException exception) {
        verificationFailed = true;
        getLogger().warning(
          "Could not verify Discord membership for guild " +
            guildId +
            ": " +
            exception.getClass().getSimpleName()
        );
      }
    }

    if (!verificationFailed) {
      cacheMembership(discordId, false);
    }
    event.disallow(
      verificationFailed
        ? AsyncPlayerPreLoginEvent.Result.KICK_OTHER
        : AsyncPlayerPreLoginEvent.Result.KICK_WHITELIST,
      verificationFailed ? verificationFailedMessage : notAllowedMessage
    );
  }

  private Component message(String path, String defaultValue) {
    return LegacyComponentSerializer.legacyAmpersand().deserialize(
      getConfig().getString(path, defaultValue)
    );
  }

  private int positiveConfigInt(String path, int defaultValue) {
    int value = getConfig().getInt(path, defaultValue);
    if (value > 0) {
      return value;
    }
    getLogger().warning(path + " must be positive; using " + defaultValue);
    return defaultValue;
  }

  private void cacheMembership(String discordId, boolean allowed) {
    membershipCache.put(
      discordId,
      new MembershipCacheEntry(
        allowed,
        System.nanoTime() + membershipCacheNanos
      )
    );
  }

  private PlayerIdentity playerIdentity(Player player) {
    return new PlayerIdentity(player.getUniqueId(), player.getName());
  }

  private void rememberPendingMinecraftName(UUID uuid, String name) {
    purgeExpiredPendingMinecraftNames();
    if (pendingMinecraftNames.size() >= MAX_PENDING_MINECRAFT_NAMES) {
      evictOldestPendingMinecraftName();
    }
    pendingMinecraftNames.put(
      uuid,
      new MinecraftNameCacheEntry(
        name,
        System.nanoTime() + PENDING_NAME_TTL_NANOS
      )
    );
  }

  private String pendingMinecraftName(UUID uuid) {
    MinecraftNameCacheEntry cached = pendingMinecraftNames.get(uuid);
    if (cached == null) {
      return null;
    }
    if (cached.isExpired()) {
      pendingMinecraftNames.remove(uuid, cached);
      return null;
    }
    return cached.name();
  }

  private void evictOldestPendingMinecraftName() {
    UUID oldestUuid = null;
    long oldestExpiry = Long.MAX_VALUE;
    for (var entry : pendingMinecraftNames.entrySet()) {
      if (entry.getValue().expiresAtNanos() < oldestExpiry) {
        oldestUuid = entry.getKey();
        oldestExpiry = entry.getValue().expiresAtNanos();
      }
    }
    if (oldestUuid != null) {
      pendingMinecraftNames.remove(oldestUuid);
    }
  }

  private void rememberLinkedMinecraftName(Player player) {
    String discordId = DiscordSRV.getPlugin()
      .getAccountLinkManager()
      .getDiscordId(player.getUniqueId());
    if (discordId != null) {
      rememberLinkedMinecraftName(player.getUniqueId(), player.getName());
    }
  }

  private void rememberLinkedMinecraftName(UUID uuid, String name) {
    if (name == null || name.isBlank()) {
      return;
    }
    linkedMinecraftNames.put(uuid, name);
    pendingMinecraftNames.remove(uuid);
  }

  private void purgeExpiredCaches() {
    purgeExpiredPendingMinecraftNames();
    membershipCache.entrySet().removeIf(entry -> entry.getValue().isExpired());
    discordProfiles
      .entrySet()
      .removeIf(entry -> entry.getValue().isExpired());
  }

  private void purgeExpiredPendingMinecraftNames() {
    pendingMinecraftNames
      .entrySet()
      .removeIf(entry -> entry.getValue().isExpired());
  }

  static long remainingRequestNanos(long deadlineNanos, long nowNanos) {
    return Math.max(0, deadlineNanos - nowNanos);
  }

  static boolean isNewSuccessfulLink(
    UUID pendingUuid,
    UUID linkedBefore,
    UUID linkedAfter
  ) {
    return (
      pendingUuid != null &&
      !pendingUuid.equals(linkedBefore) &&
      pendingUuid.equals(linkedAfter)
    );
  }

  static String linkedDisplayName(String minecraftName, String discordName) {
    return minecraftName + " (" + discordName + ")";
  }

  static String webhookDisplayName(String discordName, String minecraftName) {
    return discordName + "（" + minecraftName + "）";
  }

  static String webhookAvatarUrl(
    String discordAvatarUrl,
    String minecraftAvatarUrl
  ) {
    return discordAvatarUrl == null || discordAvatarUrl.isBlank()
      ? minecraftAvatarUrl
      : discordAvatarUrl;
  }

  static boolean shouldSuppressSystemMessage(
    boolean vanished,
    boolean silentPermission
  ) {
    return vanished || silentPermission;
  }

  private String readinessFailure() {
    if (allowedGuildIds.isEmpty()) {
      return "allowed-guild-ids-empty";
    }
    if (!DiscordSRV.isReady) {
      return "discordsrv-not-ready";
    }
    for (String guildId : allowedGuildIds) {
      if (DiscordSRV.getPlugin().getJda().getGuildById(guildId) == null) {
        return "guild-unavailable:" + guildId;
      }
    }
    return null;
  }

  private record MembershipCacheEntry(boolean allowed, long expiresAtNanos) {
    private boolean isExpired() {
      return System.nanoTime() >= expiresAtNanos;
    }
  }

  private record MinecraftNameCacheEntry(
    String name,
    long expiresAtNanos
  ) {
    private boolean isExpired() {
      return System.nanoTime() >= expiresAtNanos;
    }
  }

  private record DiscordProfileCacheEntry(
    String name,
    String avatarUrl,
    long expiresAtNanos
  ) {
    private boolean isExpired() {
      return System.nanoTime() >= expiresAtNanos;
    }
  }

  private record GuildMemberKey(String guildId, String discordId) {}

  private record PlayerIdentity(UUID uuid, String name) {}

  private record WebhookIdentity(String name, String avatarUrl) {}
}
