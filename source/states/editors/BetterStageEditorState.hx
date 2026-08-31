package states.editors;

import backend.StageData;
import backend.PsychCamera;
import objects.Character;
import psychlua.ModchartSprite;
import states.editors.StageEditorState.StageEditorMetaSprite;

import flixel.FlxObject;
import flixel.util.FlxDestroyUtil;

import openfl.utils.Assets;
import openfl.net.FileReference;
import openfl.events.Event;
import openfl.events.IOErrorEvent;

/**
 * Better Stage Editor
 * - Fully compatible with the same stage .json format as the vanilla Stage Editor.
 * - Adds: drag-to-move objects/characters directly with mouse/touch, a Layers panel,
 *   an in-app image picker that pulls straight from the current mod's images/ folder
 *   (instead of a desktop file browser), and a GF visibility toggle.
 */
class BetterStageEditorState extends MusicBeatState implements PsychUIEventHandler.PsychUIEvent
{
	final minZoom = 0.1;
	final maxZoom = 2;

	var gf:Character;
	var dad:Character;
	var boyfriend:Character;
	var stageJson:StageFile;

	var camGame:FlxCamera;
	public var camHUD:FlxCamera;

	var lastLoadedStage:String;
	var camFollow:FlxObject = new FlxObject(0, 0, 1, 1);
	var unsavedProgress:Bool = false;

	var stageSprites:Array<StageEditorMetaSprite> = [];
	var selectionSprites:FlxSpriteGroup = new FlxSpriteGroup();

	public function new(stageToLoad:String = 'stage', cachedJson:StageFile = null)
	{
		lastLoadedStage = stageToLoad;
		stageJson = cachedJson;
		super();
	}

	override function create()
	{
		Paths.clearStoredMemory();
		Paths.clearUnusedMemory();

		camGame = initPsychCamera();
		camHUD = new FlxCamera();
		camHUD.bgColor.alpha = 0;
		FlxG.cameras.add(camHUD, false);

		#if DISCORD_ALLOWED
		DiscordClient.changePresence('Better Stage Editor', 'Stage: ' + lastLoadedStage);
		#end

		if(stageJson == null) stageJson = StageData.getStageFile(lastLoadedStage);
		FlxG.camera.follow(null, LOCKON, 0);

		loadJsonAssetDirectory();
		gf = new Character(0, 0, stageJson._editorMeta != null ? stageJson._editorMeta.gf : 'gf');
		gf.visible = !(stageJson.hide_girlfriend);
		gf.scrollFactor.set(0.95, 0.95);
		dad = new Character(0, 0, stageJson._editorMeta != null ? stageJson._editorMeta.dad : 'dad');
		boyfriend = new Character(0, 0, stageJson._editorMeta != null ? stageJson._editorMeta.boyfriend : 'bf', true);

		for (i in 0...4)
		{
			var spr:FlxSprite = new FlxSprite().makeGraphic(1, 1, FlxColor.LIME);
			spr.alpha = 0.8;
			selectionSprites.add(spr);
		}

		FlxG.camera.zoom = stageJson.defaultZoom;
		repositionGirlfriend();
		repositionDad();
		repositionBoyfriend();
		var point = focusOnTarget('boyfriend');
		FlxG.camera.scroll.set(point.x - FlxG.width/2, point.y - FlxG.height/2);

		screenUI();
		editorUI();

		add(camFollow);
		updateSpriteList();

		addHelpScreen();
		FlxG.mouse.visible = true;

		addTouchPad('LEFT_FULL', 'CHARACTER_EDITOR');
		addTouchPadCamera();

		super.create();
	}

	function loadJsonAssetDirectory()
	{
		var directory:String = 'shared';
		var weekDir:String = stageJson.directory;
		if (weekDir != null && weekDir.length > 0 && weekDir != '') directory = weekDir;

		Paths.setCurrentLevel(directory);
	}

	var showSelectionQuad:Bool = true;
	var helpBg:FlxSprite;
	var helpTexts:FlxSpriteGroup;
	function addHelpScreen()
	{
		var str:Array<String> = [
			"Click and Drag - Move Object",
			"Right Click Drag - Pan Camera",
			"E/Q - Camera Zoom In/Out",
			"R - Reset Camera Zoom",
			"",
			"F1 - Toggle Help",
			"F2 - Toggle HUD",
			"F12 - Toggle Selection Outline",
			"Hold Shift - Move 4x faster",
			"Hold Control - Move Slower/Precise"
		];

		helpBg = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		helpBg.scale.set(FlxG.width, FlxG.height);
		helpBg.updateHitbox();
		helpBg.alpha = 0.6;
		helpBg.cameras = [camHUD];
		helpBg.active = helpBg.visible = false;
		add(helpBg);

		helpTexts = new FlxSpriteGroup();
		helpTexts.cameras = [camHUD];
		for (i => txt in str)
		{
			if(txt.length < 1) continue;

			var helpText:FlxText = new FlxText(0, 0, 680, txt, 16);
			helpText.setFormat(null, 16, FlxColor.WHITE, CENTER, OUTLINE_FAST, FlxColor.BLACK);
			helpText.borderColor = FlxColor.BLACK;
			helpText.scrollFactor.set();
			helpText.borderSize = 1;
			helpText.screenCenter();
			add(helpText);
			helpText.y += ((i - str.length/2) * 32) + 16;
			helpText.active = false;
			helpTexts.add(helpText);
		}
		helpTexts.active = helpTexts.visible = false;
		add(helpTexts);
	}

	function updateSpriteList()
	{
		for (spr in stageSprites)
			if(spr != null && !StageData.reservedNames.contains(spr.type))
				spr.sprite = FlxDestroyUtil.destroy(spr.sprite);

		stageSprites = [];
		var list:Map<String, FlxSprite> = [];
		if(stageJson.objects != null && stageJson.objects.length > 0)
		{
			list = StageData.addObjectsToState(stageJson.objects, gf, dad, boyfriend, null, true);
			for (key => spr in list)
				stageSprites[spr.ID] = new StageEditorMetaSprite(stageJson.objects[spr.ID], spr);
		}

		for (character in ['gf', 'dad', 'boyfriend'])
			if(!list.exists(character))
				stageSprites.push(new StageEditorMetaSprite({type: character}, Reflect.field(this, character)));

		updateLayerListRadio();
	}

	// ______________________________ UI: Layers Panel ______________________________

	var layerListBox:PsychUIBox;
	var layerRadioGroup:PsychUIRadioGroup;
	var focusRadioGroup:PsychUIRadioGroup;
	var outputTxt:FlxText;
	var posTxt:FlxText;

	function screenUI()
	{
		layerListBox = new PsychUIBox(25, 40, 250, 200, ['Layers']);
		layerListBox.scrollFactor.set();
		layerListBox.cameras = [camHUD];
		add(layerListBox);
		addLayerListBox();

		var bg:FlxSprite = new FlxSprite(0, FlxG.height - 60).makeGraphic(1, 1, FlxColor.BLACK);
		bg.cameras = [camHUD];
		bg.alpha = 0.4;
		bg.scale.set(FlxG.width, FlxG.height - bg.y);
		bg.updateHitbox();
		add(bg);

		var tipText:FlxText = new FlxText(0, FlxG.height - 44, 300, 'Press F1 for Help', 20);
		tipText.alignment = CENTER;
		tipText.cameras = [camHUD];
		tipText.scrollFactor.set();
		tipText.screenCenter(X);
		tipText.active = false;
		add(tipText);

		var targetTxt:FlxText = new FlxText(30, FlxG.height - 52, 300, 'Camera Target', 16);
		targetTxt.alignment = CENTER;
		targetTxt.cameras = [camHUD];
		targetTxt.scrollFactor.set();
		targetTxt.active = false;
		add(targetTxt);

		focusRadioGroup = new PsychUIRadioGroup(targetTxt.x, FlxG.height - 24, ['dad', 'boyfriend', 'gf'], 10, 0, true);
		focusRadioGroup.onClick = function() {
			var point = focusOnTarget(focusRadioGroup.labels[focusRadioGroup.checked]);
			camFollow.setPosition(point.x, point.y);
			FlxG.camera.target = camFollow;
		}
		focusRadioGroup.radios[0].label = 'Opponent';
		focusRadioGroup.radios[1].label = 'Boyfriend';
		focusRadioGroup.radios[2].label = 'Girlfriend';
		for (radio in focusRadioGroup.radios) radio.text.size = 11;
		focusRadioGroup.cameras = [camHUD];
		add(focusRadioGroup);

		posTxt = new FlxText(0, 50, 500, 'X: 0\nY: 0', 24);
		posTxt.setFormat(Paths.font('vcr.ttf'), 24, FlxColor.WHITE, CENTER, FlxTextBorderStyle.OUTLINE, FlxColor.BLACK);
		posTxt.borderSize = 2;
		posTxt.cameras = [camHUD];
		posTxt.screenCenter(X);
		posTxt.visible = false;
		add(posTxt);

		outputTxt = new FlxText(0, 0, 800, '', 24);
		outputTxt.alignment = CENTER;
		outputTxt.borderStyle = OUTLINE_FAST;
		outputTxt.borderSize = 1;
		outputTxt.cameras = [camHUD];
		outputTxt.screenCenter();
		outputTxt.alpha = 0;
		add(outputTxt);
	}

	var createPopup:FlxSpriteGroup;
	function addLayerListBox()
	{
		var tab_group = layerListBox.getTab('Layers').menu;
		layerRadioGroup = new PsychUIRadioGroup(10, 10, [], 25, 18, false, 200);
		layerRadioGroup.cameras = [camHUD];
		layerRadioGroup.onClick = function() updateSelectedUI();
		tab_group.add(layerRadioGroup);

		var buttonX = layerListBox.x + layerListBox.width - 10;
		var buttonY = layerRadioGroup.y - 30;

		var buttonMoveUp:PsychUIButton = new PsychUIButton(buttonX, buttonY, 'Move Up', function()
		{
			var spr = getSelected(false);
			if(spr == null) return;

			var idx:Int = stageSprites.indexOf(spr);
			var newSel:Int = Std.int(Math.min(stageSprites.length-1, idx + 1));
			stageSprites.remove(spr);
			stageSprites.insert(newSel, spr);
			updateLayerListRadio();
			unsavedProgress = true;
		});
		buttonMoveUp.cameras = [camHUD];
		tab_group.add(buttonMoveUp);

		var buttonMoveDown:PsychUIButton = new PsychUIButton(buttonX, buttonY + 30, 'Move Down', function()
		{
			var spr = getSelected(false);
			if(spr == null) return;

			var idx:Int = stageSprites.indexOf(spr);
			var newSel:Int = Std.int(Math.max(0, idx - 1));
			stageSprites.remove(spr);
			stageSprites.insert(newSel, spr);
			updateLayerListRadio();
			unsavedProgress = true;
		});
		buttonMoveDown.cameras = [camHUD];
		tab_group.add(buttonMoveDown);

		var buttonCreate:PsychUIButton = new PsychUIButton(buttonX, buttonY + 60, 'New', function() createPopup.visible = createPopup.active = true);
		buttonCreate.cameras = [camHUD];
		buttonCreate.normalStyle.bgColor = FlxColor.GREEN;
		buttonCreate.normalStyle.textColor = FlxColor.WHITE;
		tab_group.add(buttonCreate);

		var buttonDelete:PsychUIButton = new PsychUIButton(buttonX, buttonY + 90, 'Delete', function()
		{
			var spr = getSelected();
			if(spr == null) return;

			stageSprites.remove(spr);
			spr.sprite = FlxDestroyUtil.destroy(spr.sprite);
			updateLayerListRadio();
			unsavedProgress = true;
		});
		buttonDelete.cameras = [camHUD];
		buttonDelete.normalStyle.bgColor = FlxColor.RED;
		buttonDelete.normalStyle.textColor = FlxColor.WHITE;
		tab_group.add(buttonDelete);

		createPopup = new FlxSpriteGroup();
		createPopup.cameras = [camHUD];

		var bg:FlxSprite = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		bg.alpha = 0.6;
		bg.scale.set(300, 200);
		bg.updateHitbox();
		bg.screenCenter();
		createPopup.add(bg);

		var txt:FlxText = new FlxText(0, bg.y + 10, 180, 'New Layer', 24);
		txt.screenCenter(X);
		txt.alignment = CENTER;
		createPopup.add(txt);

		var btnY:Float = bg.y + 60;
		var btn:PsychUIButton = new PsychUIButton(0, btnY, 'From Mod Image...', function()
		{
			createPopup.visible = createPopup.active = false;
			openImagePicker(function(imgKey:String)
			{
				var meta:StageEditorMetaSprite = new StageEditorMetaSprite({type: 'sprite', scale: [1, 1], scroll: [1, 1], name: findUnoccupiedName()}, new ModchartSprite());
				meta.image = imgKey;
				meta.sprite.screenCenter();
				insertMeta(meta);
			});
		});
		btn.screenCenter(X);
		createPopup.add(btn);

		btnY += 50;
		var btn:PsychUIButton = new PsychUIButton(0, btnY, 'Solid Color', function() {
			var meta:StageEditorMetaSprite = new StageEditorMetaSprite({type: 'square', scale: [200, 200], name: findUnoccupiedName()}, new ModchartSprite());
			meta.sprite.makeGraphic(1, 1, FlxColor.WHITE);
			meta.sprite.scale.set(200, 200);
			meta.sprite.updateHitbox();
			meta.sprite.screenCenter();
			insertMeta(meta);
		});
		btn.screenCenter(X);
		createPopup.add(btn);

		btnY += 50;
		var btn:PsychUIButton = new PsychUIButton(0, btnY, 'Cancel', function() createPopup.visible = createPopup.active = false);
		btn.screenCenter(X);
		createPopup.add(btn);

		add(createPopup);
		createPopup.visible = createPopup.active = false;
	}

	function findUnoccupiedName(prefix = 'layer')
	{
		var num:Int = 1;
		var name:String = 'unnamed';
		while(true)
		{
			var cantUseName:Bool = false;
			name = prefix + num;
			for (basic in stageSprites)
				if(basic.name == name) { cantUseName = true; break; }

			if(cantUseName) { num++; continue; }
			break;
		}
		return name;
	}

	function insertMeta(meta:StageEditorMetaSprite)
	{
		stageSprites.push(meta);
		updateLayerListRadio();
		layerRadioGroup.checked = 0;
		updateSelectedUI();
		unsavedProgress = true;
	}

	function updateLayerListRadio()
	{
		var _sel:String = (layerRadioGroup.checkedRadio != null ? layerRadioGroup.checkedRadio.label : null);
		var nameList:Array<String> = [];
		for (spr in stageSprites)
		{
			if(spr == null) continue;
			switch(spr.type)
			{
				case 'gf': nameList.push('- Girlfriend -');
				case 'boyfriend': nameList.push('- Boyfriend -');
				case 'dad': nameList.push('- Opponent -');
				default: nameList.push(spr.name);
			}
		}
		nameList.reverse();

		layerRadioGroup.labels = nameList;
		for (radio in layerRadioGroup.radios)
			if(radio.label == _sel) { layerRadioGroup.checkedRadio = radio; break; }

		final maxNum:Int = 19;
		layerListBox.resize(250, Std.int(Math.min(maxNum, layerRadioGroup.labels.length) * 25 + 35));
	}

	function getSelected(blockReserved:Bool = true):StageEditorMetaSprite
	{
		var selected:Int = layerRadioGroup.checked;
		if(selected >= 0)
		{
			var spr = stageSprites[layerRadioGroup.labels.length - selected - 1];
			if(spr != null && (!blockReserved || !StageData.reservedNames.contains(spr.type)))
				return spr;
		}
		return null;
	}

	function selectSpriteInList(target:StageEditorMetaSprite)
	{
		var idx:Int = stageSprites.indexOf(target);
		if(idx < 0) return;
		layerRadioGroup.checked = layerRadioGroup.labels.length - idx - 1;
		updateSelectedUI();
	}

	// ______________________________ UI: Object Editing Panel ______________________________

	var editBox:PsychUIBox;
	var stageBox:PsychUIBox;

	var directoryDropDown:PsychUIDropDownMenu;
	var uiInputText:PsychUIInputText;
	var hideGirlfriendCheckbox:PsychUICheckBox;
	var zoomStepper:PsychUINumericStepper;
	var cameraSpeedStepper:PsychUINumericStepper;
	var camDadStepperX:PsychUINumericStepper;
	var camDadStepperY:PsychUINumericStepper;
	var camGfStepperX:PsychUINumericStepper;
	var camGfStepperY:PsychUINumericStepper;
	var camBfStepperX:PsychUINumericStepper;
	var camBfStepperY:PsychUINumericStepper;

	var colorInputText:PsychUIInputText;
	var nameInputText:PsychUIInputText;
	var imgTxt:FlxText;
	var scaleStepperX:PsychUINumericStepper;
	var scaleStepperY:PsychUINumericStepper;
	var scrollStepperX:PsychUINumericStepper;
	var scrollStepperY:PsychUINumericStepper;
	var angleStepper:PsychUINumericStepper;
	var alphaStepper:PsychUINumericStepper;
	var antialiasingCheckbox:PsychUICheckBox;
	var flipXCheckBox:PsychUICheckBox;
	var flipYCheckBox:PsychUICheckBox;
	var lowQualityCheckbox:PsychUICheckBox;
	var highQualityCheckbox:PsychUICheckBox;

	var oppDropdown:PsychUIDropDownMenu;
	var gfDropdown:PsychUIDropDownMenu;
	var plDropdown:PsychUIDropDownMenu;
	var stageDropDown:PsychUIDropDownMenu;

	function editorUI()
	{
		editBox = new PsychUIBox(FlxG.width - 225, 10, 200, 420, ['Object', 'Characters', 'Stage']);
		editBox.cameras = [camHUD];
		editBox.scrollFactor.set();
		add(editBox);
		editBox.selectedName = 'Object';

		stageBox = new PsychUIBox(FlxG.width - 275, 25, 250, 100, ['Camera & Stage']);
		stageBox.cameras = [camHUD];
		stageBox.scrollFactor.set();
		add(stageBox);
		editBox.y += stageBox.y + stageBox.height;

		addObjectTab();
		addCharactersTab();
		addStageTab();
	}

	function addObjectTab()
	{
		var tab_group = editBox.getTab('Object').menu;

		var objX = 10;
		var objY = 30;
		tab_group.add(new FlxText(objX, objY - 18, 150, 'Name (for Lua/HScript):'));
		nameInputText = new PsychUIInputText(objX, objY, 120, '', 8);
		nameInputText.customFilterPattern = ~/[^a-zA-Z0-9_\-]*/g;
		nameInputText.onChange = function(old:String, cur:String) {
			var selected = getSelected();
			if(selected == null) return;

			var changedName:String = nameInputText.text;
			if(changedName.length < 1) { showOutput('Layer name cannot be empty!', true); return; }
			if(StageData.reservedNames.contains(changedName)) { showOutput('This name is reserved!', true); return; }

			for (basic in stageSprites)
				if (selected != basic && basic.name == changedName) { showOutput('Name "$changedName" is already in use!', true); return; }

			selected.name = changedName;
			layerRadioGroup.checkedRadio.label = selected.name;
			outputTime = 0;
			outputTxt.alpha = 0;
		};
		tab_group.add(nameInputText);

		objY += 35;
		imgTxt = new FlxText(objX, objY - 15, 200, 'Image: ', 8);
		var imgButton:PsychUIButton = new PsychUIButton(objX, objY, 'Change Image', function() {
			var selected = getSelected();
			if(selected == null) return;

			openImagePicker(function(imgKey:String)
			{
				tryLoadImage(selected, imgKey);
			});
		});
		tab_group.add(imgButton);
		tab_group.add(imgTxt);

		objY += 45;
		tab_group.add(new FlxText(objX, objY - 18, 80, 'Color:'));
		colorInputText = new PsychUIInputText(objX, objY, 80, 'FFFFFF', 8);
		colorInputText.filterMode = ONLY_ALPHANUMERIC;
		colorInputText.onChange = function(old:String, cur:String) {
			var selected = getSelected();
			if(selected != null) selected.color = colorInputText.text;
		};
		tab_group.add(colorInputText);

		function updateScale()
		{
			var selected = getSelected();
			if(selected != null) selected.setScale(scaleStepperX.value, scaleStepperY.value);
		}

		objY += 45;
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Scale (X/Y):'));
		scaleStepperX = new PsychUINumericStepper(objX, objY, 0.05, 1, 0.05, 10, 2);
		scaleStepperY = new PsychUINumericStepper(objX + 70, objY, 0.05, 1, 0.05, 10, 2);
		scaleStepperX.onValueChange = scaleStepperY.onValueChange = updateScale;
		tab_group.add(scaleStepperX);
		tab_group.add(scaleStepperY);

		function updateScroll()
		{
			var selected = getSelected();
			if(selected != null) selected.setScrollFactor(scrollStepperX.value, scrollStepperY.value);
		}

		objY += 40;
		tab_group.add(new FlxText(objX, objY - 18, 150, 'Scroll Factor (X/Y):'));
		scrollStepperX = new PsychUINumericStepper(objX, objY, 0.05, 1, 0, 10, 2);
		scrollStepperY = new PsychUINumericStepper(objX + 70, objY, 0.05, 1, 0, 10, 2);
		scrollStepperX.onValueChange = scrollStepperY.onValueChange = updateScroll;
		tab_group.add(scrollStepperX);
		tab_group.add(scrollStepperY);

		objY += 40;
		tab_group.add(new FlxText(objX, objY - 18, 80, 'Opacity:'));
		alphaStepper = new PsychUINumericStepper(objX, objY, 0.1, 1, 0, 1, 2, true);
		alphaStepper.onValueChange = function() {
			var selected = getSelected();
			if(selected != null) selected.alpha = alphaStepper.value;
		};
		tab_group.add(alphaStepper);

		antialiasingCheckbox = new PsychUICheckBox(objX + 90, objY, 'Anti-Aliasing', 80);
		antialiasingCheckbox.onClick = function()
		{
			var selected = getSelected();
			if(selected != null)
			{
				if(selected.type != 'square') selected.antialiasing = antialiasingCheckbox.checked;
				else { antialiasingCheckbox.checked = false; selected.antialiasing = false; }
			}
		};
		tab_group.add(antialiasingCheckbox);

		objY += 40;
		tab_group.add(new FlxText(objX, objY - 18, 80, 'Angle:'));
		angleStepper = new PsychUINumericStepper(objX, objY, 10, 0, 0, 360, 0);
		angleStepper.onValueChange = function() {
			var selected = getSelected();
			if(selected != null) selected.angle = angleStepper.value;
		};
		tab_group.add(angleStepper);

		function updateFlip()
		{
			var selected = getSelected();
			if(selected != null)
			{
				if(selected.type != 'square') { selected.flipX = flipXCheckBox.checked; selected.flipY = flipYCheckBox.checked; }
				else { flipXCheckBox.checked = flipYCheckBox.checked = false; selected.flipX = selected.flipY = false; }
			}
		}

		objY += 25;
		flipXCheckBox = new PsychUICheckBox(objX, objY, 'Flip X', 60);
		flipXCheckBox.onClick = updateFlip;
		flipYCheckBox = new PsychUICheckBox(objX + 90, objY, 'Flip Y', 60);
		flipYCheckBox.onClick = updateFlip;
		tab_group.add(flipXCheckBox);
		tab_group.add(flipYCheckBox);

		objY += 45;
		function recalcFilter()
		{
			var selected = getSelected();
			if(selected != null)
			{
				var filt = 0;
				if(lowQualityCheckbox.checked) filt |= LOW_QUALITY;
				if(highQualityCheckbox.checked) filt |= HIGH_QUALITY;
				selected.filters = filt;
			}
		};
		tab_group.add(new FlxText(objX + 60, objY - 18, 100, 'Visible in:'));
		lowQualityCheckbox = new PsychUICheckBox(objX, objY, 'Low Quality', 70);
		highQualityCheckbox = new PsychUICheckBox(objX + 90, objY, 'High Quality', 70);
		lowQualityCheckbox.onClick = recalcFilter;
		highQualityCheckbox.onClick = recalcFilter;
		tab_group.add(lowQualityCheckbox);
		tab_group.add(highQualityCheckbox);
	}

	function addCharactersTab()
	{
		var tab_group = editBox.getTab('Characters').menu;

		var characterList = Mods.mergeAllTextsNamed('data/characterList.txt');
		var foldersToCheck:Array<String> = Mods.directoriesWithFile(Paths.getSharedPath(), 'characters/');
		for (folder in foldersToCheck)
			for (file in Paths.readDirectory(folder))
				if(file.toLowerCase().endsWith('.json'))
				{
					var charToCheck:String = file.substr(0, file.length - 5);
					if(!characterList.contains(charToCheck)) characterList.push(charToCheck);
				}
		if(characterList.length < 1) characterList.push('');

		var objX = 10;
		var objY = 20;

		function setMetaData(data:String, char:String)
		{
			if(stageJson._editorMeta == null) stageJson._editorMeta = {dad: 'dad', gf: 'gf', boyfriend: 'bf'};
			Reflect.setField(stageJson._editorMeta, data, char);
			unsavedProgress = true;
		}

		plDropdown = new PsychUIDropDownMenu(objX, objY, characterList, function(sel:Int, selected:String)
		{
			if(selected == null || selected.length < 1) return;
			boyfriend.changeCharacter(selected);
			setMetaData('boyfriend', selected);
			repositionBoyfriend();
		});
		plDropdown.selectedLabel = boyfriend.curCharacter;

		objY += 60;
		gfDropdown = new PsychUIDropDownMenu(objX, objY, characterList, function(sel:Int, selected:String)
		{
			if(selected == null || selected.length < 1) return;
			gf.changeCharacter(selected);
			setMetaData('gf', selected);
			repositionGirlfriend();
		});
		gfDropdown.selectedLabel = gf.curCharacter;

		objY += 60;
		oppDropdown = new PsychUIDropDownMenu(objX, objY, characterList, function(sel:Int, selected:String)
		{
			if(selected == null || selected.length < 1) return;
			dad.changeCharacter(selected);
			setMetaData('dad', selected);
			repositionDad();
		});
		oppDropdown.selectedLabel = dad.curCharacter;

		objY += 50;
		hideGirlfriendCheckbox = new PsychUICheckBox(objX, objY, 'Hide Girlfriend?', 100);
		hideGirlfriendCheckbox.onClick = function()
		{
			stageJson.hide_girlfriend = hideGirlfriendCheckbox.checked;
			gf.visible = !hideGirlfriendCheckbox.checked;
			unsavedProgress = true;
			_updateCamera();
		};
		hideGirlfriendCheckbox.checked = !gf.visible;

		tab_group.add(new FlxText(plDropdown.x, plDropdown.y - 18, 100, 'Boyfriend:'));
		tab_group.add(plDropdown);
		tab_group.add(new FlxText(gfDropdown.x, gfDropdown.y - 18, 100, 'Girlfriend:'));
		tab_group.add(gfDropdown);
		tab_group.add(new FlxText(oppDropdown.x, oppDropdown.y - 18, 100, 'Opponent:'));
		tab_group.add(oppDropdown);
		tab_group.add(hideGirlfriendCheckbox);
	}

	function addStageTab()
	{
		var tab_group = stageBox.getTab('Camera & Stage').menu;

		var objX = 10;
		var objY = 20;

		var saveButton:PsychUIButton = new PsychUIButton(160, 10, 'Save', function() saveData());
		saveButton.normalStyle.bgColor = FlxColor.GREEN;
		saveButton.normalStyle.textColor = FlxColor.WHITE;
		tab_group.add(saveButton);

		var reloadStage:PsychUIButton = new PsychUIButton(160, 40, 'Reload', function()
		{
			stageJson = StageData.getStageFile(lastLoadedStage);
			updateSpriteList();
			updateStageDataUI();
			reloadCharacters();
			reloadStageDropDown();
		});
		tab_group.add(reloadStage);

		objY += 60;
		stageDropDown = new PsychUIDropDownMenu(objX, objY, [''], function(sel:Int, selected:String)
		{
			var characterPath:String = 'stages/$selected.json';
			var path:String = Paths.getPath(characterPath, TEXT, null, true);
			#if MODS_ALLOWED
			if (FileSystem.exists(path))
			#else
			if (Assets.exists(path))
			#end
			{
				stageJson = StageData.getStageFile(selected);
				lastLoadedStage = selected;
				updateSpriteList();
				updateStageDataUI();
				reloadCharacters();
				reloadStageDropDown();
			}
			else
			{
				FlxG.sound.play(Paths.sound('cancelMenu'));
				reloadStageDropDown();
			}
		});
		tab_group.add(new FlxText(stageDropDown.x, stageDropDown.y - 18, 60, 'Stage:'));
		tab_group.add(stageDropDown);

		objY += 55;
		var folderList:Array<String> = [''];
		#if sys
		for (folder in Paths.readDirectory('assets/'))
			if(FileSystem.isDirectory('assets/$folder') && folder != 'shared' && !Mods.ignoreModFolders.contains(folder))
				folderList.push(folder);
		#end
		directoryDropDown = new PsychUIDropDownMenu(objX, objY, folderList, function(sel:Int, selected:String) {
			stageJson.directory = selected;
			saveObjectsToJson();
			FlxTransitionableState.skipNextTransIn = FlxTransitionableState.skipNextTransOut = true;
			MusicBeatState.switchState(new BetterStageEditorState(lastLoadedStage, stageJson));
		});
		directoryDropDown.selectedLabel = stageJson.directory;
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Asset Directory:'));
		tab_group.add(directoryDropDown);

		objY += 50;
		tab_group.add(new FlxText(objX, objY - 18, 100, 'UI Style:'));
		uiInputText = new PsychUIInputText(objX, objY, 100, stageJson.stageUI != null ? stageJson.stageUI : '', 8);
		uiInputText.onChange = function(old:String, cur:String) { stageJson.stageUI = uiInputText.text; unsavedProgress = true; };
		tab_group.add(uiInputText);

		objY += 45;
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Camera Offsets:'));
		objY += 20;
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Opponent:'));
		var cx:Float = 0; var cy:Float = 0;
		if(stageJson.camera_opponent != null && stageJson.camera_opponent.length > 1) { cx = stageJson.camera_opponent[0]; cy = stageJson.camera_opponent[1]; }
		camDadStepperX = new PsychUINumericStepper(objX, objY, 50, cx, -10000, 10000, 0);
		camDadStepperY = new PsychUINumericStepper(objX + 80, objY, 50, cy, -10000, 10000, 0);
		camDadStepperX.onValueChange = camDadStepperY.onValueChange = function() {
			if(stageJson.camera_opponent == null) stageJson.camera_opponent = [0, 0];
			stageJson.camera_opponent[0] = camDadStepperX.value;
			stageJson.camera_opponent[1] = camDadStepperY.value;
			unsavedProgress = true;
			_updateCamera();
		};
		tab_group.add(camDadStepperX);
		tab_group.add(camDadStepperY);

		objY += 40;
		var cx:Float = 0; var cy:Float = 0;
		if(stageJson.camera_girlfriend != null && stageJson.camera_girlfriend.length > 1) { cx = stageJson.camera_girlfriend[0]; cy = stageJson.camera_girlfriend[1]; }
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Girlfriend:'));
		camGfStepperX = new PsychUINumericStepper(objX, objY, 50, cx, -10000, 10000, 0);
		camGfStepperY = new PsychUINumericStepper(objX + 80, objY, 50, cy, -10000, 10000, 0);
		camGfStepperX.onValueChange = camGfStepperY.onValueChange = function() {
			if(stageJson.camera_girlfriend == null) stageJson.camera_girlfriend = [0, 0];
			stageJson.camera_girlfriend[0] = camGfStepperX.value;
			stageJson.camera_girlfriend[1] = camGfStepperY.value;
			unsavedProgress = true;
			_updateCamera();
		};
		tab_group.add(camGfStepperX);
		tab_group.add(camGfStepperY);

		objY += 40;
		var cx:Float = 0; var cy:Float = 0;
		if(stageJson.camera_boyfriend != null && stageJson.camera_boyfriend.length > 1) { cx = stageJson.camera_boyfriend[0]; cy = stageJson.camera_boyfriend[1]; }
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Boyfriend:'));
		camBfStepperX = new PsychUINumericStepper(objX, objY, 50, cx, -10000, 10000, 0);
		camBfStepperY = new PsychUINumericStepper(objX + 80, objY, 50, cy, -10000, 10000, 0);
		camBfStepperX.onValueChange = camBfStepperY.onValueChange = function() {
			if(stageJson.camera_boyfriend == null) stageJson.camera_boyfriend = [0, 0];
			stageJson.camera_boyfriend[0] = camBfStepperX.value;
			stageJson.camera_boyfriend[1] = camBfStepperY.value;
			unsavedProgress = true;
			_updateCamera();
		};
		tab_group.add(camBfStepperX);
		tab_group.add(camBfStepperY);

		objY += 50;
		tab_group.add(new FlxText(objX, objY - 18, 100, 'Zoom:'));
		zoomStepper = new PsychUINumericStepper(objX, objY, 0.05, stageJson.defaultZoom, minZoom, maxZoom, 2);
		zoomStepper.onValueChange = function() {
			stageJson.defaultZoom = zoomStepper.value;
			FlxG.camera.zoom = stageJson.defaultZoom;
			unsavedProgress = true;
		};
		tab_group.add(zoomStepper);

		tab_group.add(new FlxText(objX + 80, objY - 18, 100, 'Speed:'));
		cameraSpeedStepper = new PsychUINumericStepper(objX + 80, objY, 0.1, stageJson.camera_speed != null ? stageJson.camera_speed : 1, 0, 10, 2);
		cameraSpeedStepper.onValueChange = function() {
			stageJson.camera_speed = cameraSpeedStepper.value;
			FlxG.camera.followLerp = 0.04 * stageJson.camera_speed;
			unsavedProgress = true;
		};
		FlxG.camera.followLerp = 0.04 * cameraSpeedStepper.value;
		tab_group.add(cameraSpeedStepper);

		stageBox.resize(250, 100);
		reloadStageDropDown();
	}

	function _updateCamera()
	{
		if(focusRadioGroup.checked > -1)
		{
			var point = focusOnTarget(focusRadioGroup.labels[focusRadioGroup.checked]);
			camFollow.setPosition(point.x, point.y);
		}
	}

	// ______________________________ Image Picker (mods/images) ______________________________

	var imagePickerBox:FlxSpriteGroup;
	var imagePickerRadio:PsychUIRadioGroup;
	var imagePickerCallback:String->Void;

	function openImagePicker(onPicked:String->Void)
	{
		imagePickerCallback = onPicked;

		if(imagePickerBox != null) { remove(imagePickerBox); imagePickerBox.destroy(); }

		imagePickerBox = new FlxSpriteGroup();
		imagePickerBox.cameras = [camHUD];

		var bg:FlxSprite = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		bg.alpha = 0.85;
		bg.scale.set(400, 420);
		bg.updateHitbox();
		bg.screenCenter();
		imagePickerBox.add(bg);

		var txt:FlxText = new FlxText(0, bg.y + 10, 380, 'Pick an image from mods/images', 20);
		txt.alignment = CENTER;
		txt.screenCenter(X);
		imagePickerBox.add(txt);

		var images:Array<String> = findModImages();
		var listLabels:Array<String> = images.length > 0 ? images : ['(No images found in mods/images)'];

		imagePickerRadio = new PsychUIRadioGroup(bg.x + 20, bg.y + 50, listLabels, 22, 18, false, 360);
		imagePickerRadio.cameras = [camHUD];
		imagePickerBox.add(imagePickerRadio);

		var pickButton:PsychUIButton = new PsychUIButton(0, bg.y + bg.height - 80, 'Use This Image', function()
		{
			if(images.length < 1) return;
			var idx:Int = imagePickerRadio.checked;
			if(idx < 0) return;

			var picked:String = images[idx];
			closeImagePicker();
			if(imagePickerCallback != null) imagePickerCallback(picked);
		});
		pickButton.screenCenter(X);
		pickButton.normalStyle.bgColor = FlxColor.GREEN;
		pickButton.normalStyle.textColor = FlxColor.WHITE;
		imagePickerBox.add(pickButton);

		var cancelButton:PsychUIButton = new PsychUIButton(0, bg.y + bg.height - 40, 'Cancel', function() closeImagePicker());
		cancelButton.screenCenter(X);
		imagePickerBox.add(cancelButton);

		add(imagePickerBox);
	}

	function closeImagePicker()
	{
		if(imagePickerBox != null)
		{
			remove(imagePickerBox);
			imagePickerBox.destroy();
			imagePickerBox = null;
		}
		imagePickerCallback = null;
	}

	// Scans the current mod's images/ folder (plus base assets as a fallback) for .png files.
	function findModImages():Array<String>
	{
		var found:Array<String> = [];
		#if MODS_ALLOWED
		var modFolder:String = (Mods.currentModDirectory != null && Mods.currentModDirectory.length > 0)
			? Paths.mods('${Mods.currentModDirectory}/images/')
			: Paths.mods('images/');

		if(FileSystem.exists(modFolder))
			scanImageFolder(modFolder, '', found);
		#end

		var sharedFolder:String = Paths.getSharedPath('images/');
		#if MODS_ALLOWED
		var fullSharedFolder:String = Sys.getCwd() + sharedFolder;
		if(FileSystem.exists(fullSharedFolder))
			scanImageFolder(fullSharedFolder, '', found);
		#end

		found.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		return found;
	}

	#if MODS_ALLOWED
	function scanImageFolder(folder:String, prefix:String, found:Array<String>)
	{
		for (file in FileSystem.readDirectory(folder))
		{
			var full:String = folder + '/' + file;
			if(FileSystem.isDirectory(full))
			{
				scanImageFolder(full, prefix + file + '/', found);
			}
			else if(file.toLowerCase().endsWith('.png'))
			{
				var key:String = prefix + file.substr(0, file.length - 4);
				if(!found.contains(key)) found.push(key);
			}
		}
	}
	#end

	function tryLoadImage(spr:StageEditorMetaSprite, imgPath:String)
	{
		if(spr == null || StageData.reservedNames.contains(spr.type) || spr.type == 'square' || imgPath == null) return;

		if(spr.type != 'animatedSprite')
			spr.type = 'sprite';
		spr.image = imgPath;
		updateSelectedUI();
		unsavedProgress = true;
	}

	// ______________________________ Selection / Camera Focus ______________________________

	function showOutput(txt:String, isError:Bool = false)
	{
		outputTxt.color = isError ? FlxColor.RED : FlxColor.WHITE;
		outputTxt.text = txt;
		outputTime = 3;
		if(isError) FlxG.sound.play(Paths.sound('cancelMenu'), 0.4);
		else FlxG.sound.play(Paths.sound('scrollMenu'), 0.4);
	}

	function focusOnTarget(target:String)
	{
		var focusPoint:FlxPoint = FlxPoint.weak(0, 0);
		switch(target)
		{
			case 'boyfriend':
				focusPoint.x += boyfriend.getMidpoint().x - boyfriend.cameraPosition[0] - 100;
				focusPoint.y += boyfriend.getMidpoint().y + boyfriend.cameraPosition[1] - 100;
				if(stageJson.camera_boyfriend != null && stageJson.camera_boyfriend.length > 1)
				{
					focusPoint.x += stageJson.camera_boyfriend[0];
					focusPoint.y += stageJson.camera_boyfriend[1];
				}
			case 'dad':
				focusPoint.x += dad.getMidpoint().x + dad.cameraPosition[0] + 150;
				focusPoint.y += dad.getMidpoint().y + dad.cameraPosition[1] - 100;
				if(stageJson.camera_opponent != null && stageJson.camera_opponent.length > 1)
				{
					focusPoint.x += stageJson.camera_opponent[0];
					focusPoint.y += stageJson.camera_opponent[1];
				}
			case 'gf':
				if(gf.visible)
				{
					focusPoint.x += gf.getMidpoint().x + gf.cameraPosition[0];
					focusPoint.y += gf.getMidpoint().y + gf.cameraPosition[1];
				}
				if(stageJson.camera_girlfriend != null && stageJson.camera_girlfriend.length > 1)
				{
					focusPoint.x += stageJson.camera_girlfriend[0];
					focusPoint.y += stageJson.camera_girlfriend[1];
				}
		}
		return focusPoint;
	}

	function repositionGirlfriend() { gf.setPosition(stageJson.girlfriend[0], stageJson.girlfriend[1]); gf.x += gf.positionArray[0]; gf.y += gf.positionArray[1]; }
	function repositionDad() { dad.setPosition(stageJson.opponent[0], stageJson.opponent[1]); dad.x += dad.positionArray[0]; dad.y += dad.positionArray[1]; }
	function repositionBoyfriend() { boyfriend.setPosition(stageJson.boyfriend[0], stageJson.boyfriend[1]); boyfriend.x += boyfriend.positionArray[0]; boyfriend.y += boyfriend.positionArray[1]; }

	function updateSelectedUI()
	{
		posTxt.visible = false;
		var selected = getSelected(false);
		if(selected == null) return;

		var displayX:Float = Math.round(selected.x);
		var displayY:Float = Math.round(selected.y);
		var char:Character = cast selected.sprite;
		if(char != null) { displayX -= char.positionArray[0]; displayY -= char.positionArray[1]; }

		posTxt.text = 'X: $displayX\nY: $displayY';
		posTxt.visible = true;

		var selected = getSelected();
		if(selected == null) return;

		colorInputText.text = selected.color;
		nameInputText.text = selected.name;
		imgTxt.text = 'Image: ' + selected.image;

		if (selected.type != 'square')
		{
			scaleStepperX.decimals = scaleStepperY.decimals = 2;
			scaleStepperX.max = scaleStepperY.max = 10;
			scaleStepperX.min = scaleStepperY.min = 0.05;
			scaleStepperX.step = scaleStepperY.step = 0.05;
		}
		else
		{
			scaleStepperX.decimals = scaleStepperY.decimals = 0;
			scaleStepperX.max = scaleStepperY.max = 10000;
			scaleStepperX.min = scaleStepperY.min = 50;
			scaleStepperX.step = scaleStepperY.step = 50;
		}
		scaleStepperX.value = selected.scale[0];
		scaleStepperY.value = selected.scale[1];
		scrollStepperX.value = selected.scroll[0];
		scrollStepperY.value = selected.scroll[1];
		angleStepper.value = selected.angle;
		alphaStepper.value = selected.alpha;

		antialiasingCheckbox.checked = selected.antialiasing;
		flipXCheckBox.checked = selected.flipX;
		flipYCheckBox.checked = selected.flipY;
		lowQualityCheckbox.checked = (selected.filters & LOW_QUALITY) == LOW_QUALITY;
		highQualityCheckbox.checked = (selected.filters & HIGH_QUALITY) == HIGH_QUALITY;
	}

	function reloadCharacters()
	{
		if(stageJson._editorMeta != null)
		{
			gf.changeCharacter(stageJson._editorMeta.gf);
			dad.changeCharacter(stageJson._editorMeta.dad);
			boyfriend.changeCharacter(stageJson._editorMeta.boyfriend);
		}
		repositionGirlfriend();
		repositionDad();
		repositionBoyfriend();

		focusRadioGroup.checked = -1;
		FlxG.camera.target = null;
		var point = focusOnTarget('boyfriend');
		FlxG.camera.scroll.set(point.x - FlxG.width/2, point.y - FlxG.height/2);
		FlxG.camera.zoom = stageJson.defaultZoom;
		oppDropdown.selectedLabel = dad.curCharacter;
		gfDropdown.selectedLabel = gf.curCharacter;
		plDropdown.selectedLabel = boyfriend.curCharacter;
	}

	function reloadStageDropDown()
	{
		var stageList:Array<String> = [];
		var foldersToCheck:Array<String> = Mods.directoriesWithFile(Paths.getSharedPath(), 'stages/');
		for (folder in foldersToCheck)
			for (file in Paths.readDirectory(folder))
				if(file.toLowerCase().endsWith('.json'))
				{
					var stageToCheck:String = file.substr(0, file.length - '.json'.length);
					if(!stageList.contains(stageToCheck)) stageList.push(stageToCheck);
				}

		if(stageList.length < 1) stageList.push('');
		stageDropDown.list = stageList;
		stageDropDown.selectedLabel = lastLoadedStage;
		directoryDropDown.selectedLabel = stageJson.directory;
	}

	function updateStageDataUI()
	{
		uiInputText.text = (stageJson.stageUI != null ? stageJson.stageUI : '');
		hideGirlfriendCheckbox.checked = (stageJson.hide_girlfriend);
		gf.visible = !hideGirlfriendCheckbox.checked;
		zoomStepper.value = FlxG.camera.zoom = stageJson.defaultZoom;

		if(stageJson.camera_speed != null) cameraSpeedStepper.value = stageJson.camera_speed;
		else cameraSpeedStepper.value = 1;
		FlxG.camera.followLerp = 0.04 * cameraSpeedStepper.value;

		if(stageJson.camera_opponent != null && stageJson.camera_opponent.length > 1) { camDadStepperX.value = stageJson.camera_opponent[0]; camDadStepperY.value = stageJson.camera_opponent[1]; }
		else camDadStepperX.value = camDadStepperY.value = 0;

		if(stageJson.camera_girlfriend != null && stageJson.camera_girlfriend.length > 1) { camGfStepperX.value = stageJson.camera_girlfriend[0]; camGfStepperY.value = stageJson.camera_girlfriend[1]; }
		else camGfStepperX.value = camGfStepperY.value = 0;

		if(stageJson.camera_boyfriend != null && stageJson.camera_boyfriend.length > 1) { camBfStepperX.value = stageJson.camera_boyfriend[0]; camBfStepperY.value = stageJson.camera_boyfriend[1]; }
		else camBfStepperX.value = camBfStepperY.value = 0;

		_updateCamera();
		loadJsonAssetDirectory();
	}

	function checkUIOnObject()
	{
		if(editBox.selectedName == 'Object')
		{
			var spr = getSelected(false);
			if(spr == null || StageData.reservedNames.contains(spr.type))
				editBox.selectedName = 'Characters';
		}
	}

	public function UIEvent(id:String, sender:Dynamic)
	{
		switch(id)
		{
			case PsychUIRadioGroup.CLICK_EVENT, PsychUIBox.CLICK_EVENT:
				if(sender == layerRadioGroup || sender == editBox) checkUIOnObject();
			case PsychUICheckBox.CLICK_EVENT:
				unsavedProgress = true;
			case PsychUIInputText.CHANGE_EVENT, PsychUINumericStepper.CHANGE_EVENT:
				unsavedProgress = true;
		}
	}

	override function closeSubState()
	{
		super.closeSubState();
		controls.isInSubstate = false;
		removeTouchPad();
		addTouchPad('LEFT_FULL', 'CHARACTER_EDITOR');
		addTouchPadCamera();
		persistentUpdate = true;
	}

	// ______________________________ Drag-to-Move + Update Loop ______________________________

	var draggingSprite:StageEditorMetaSprite;
	var outputTime:Float = 0;

	override function update(elapsed:Float)
	{
		var overUI:Bool = (imagePickerBox != null) || (createPopup.visible && FlxG.mouse.overlaps(createPopup, camHUD))
			|| FlxG.mouse.overlaps(layerListBox, camHUD) || FlxG.mouse.overlaps(editBox, camHUD) || FlxG.mouse.overlaps(stageBox, camHUD);

		if(createPopup.visible && (FlxG.mouse.justPressedRight || (FlxG.mouse.justPressed && !FlxG.mouse.overlaps(createPopup, camHUD))))
			createPopup.visible = createPopup.active = false;

		for (basic in stageSprites)
			basic.update(curFilters, elapsed);

		super.update(elapsed);

		outputTime = Math.max(0, outputTime - elapsed);
		outputTxt.alpha = outputTime;

		if(PsychUIInputText.focusOn != null) return;
		if(imagePickerBox != null) return; // block gameplay/editor input while the picker's open

		if(FlxG.keys.justPressed.ESCAPE || touchPad.buttonB.justPressed)
		{
			if(!unsavedProgress)
			{
				MusicBeatState.switchState(new states.editors.MasterEditorMenu());
				FlxG.sound.playMusic(Paths.music('freakyMenu'));
			}
			else openSubState(new BetterStageEditorExitPrompt());
			return;
		}

		if((FlxG.keys.justPressed.F1 || touchPad.buttonF.justPressed) || (helpBg.visible && FlxG.keys.justPressed.ESCAPE))
		{
			helpBg.visible = !helpBg.visible;
			helpTexts.visible = helpBg.visible;
		}

		if(FlxG.keys.justPressed.F2 || (touchPad.buttonS.justPressed && !touchPad.buttonF.justPressed))
		{
			editBox.visible = !editBox.visible;
			editBox.active = !editBox.active;
			var objs = [stageBox, layerRadioGroup, layerListBox];
			for (obj in objs)
			{
				obj.visible = editBox.visible;
				if(!(obj is FlxText)) obj.active = editBox.active;
			}
			layerRadioGroup.updateRadioItems();
		}

		if(FlxG.keys.justPressed.F12 || (touchPad.buttonS.justPressed && !touchPad.buttonG.justPressed))
			showSelectionQuad = !showSelectionQuad;

		var shiftMult:Float = 1;
		var ctrlMult:Float = 1;
		if(FlxG.keys.pressed.SHIFT || touchPad.buttonC.pressed) shiftMult = 4;
		if(FlxG.keys.pressed.CONTROL) ctrlMult = 0.25;

		// ---- Camera zoom ----
		if(FlxG.keys.justPressed.R || touchPad.buttonZ.justPressed && !FlxG.keys.pressed.CONTROL)
			FlxG.camera.zoom = stageJson.defaultZoom;
		else if (FlxG.keys.pressed.E || touchPad.buttonX.pressed && FlxG.camera.zoom < maxZoom)
			FlxG.camera.zoom = Math.min(maxZoom, FlxG.camera.zoom + elapsed * FlxG.camera.zoom * shiftMult * ctrlMult);
		else if (FlxG.keys.pressed.Q || touchPad.buttonY.pressed && FlxG.camera.zoom > minZoom)
			FlxG.camera.zoom = Math.max(minZoom, FlxG.camera.zoom - elapsed * FlxG.camera.zoom * shiftMult * ctrlMult);

		// ---- Right-click drag pans the camera ----
		if(!overUI && FlxG.mouse.pressedRight && (FlxG.mouse.deltaScreenX != 0 || FlxG.mouse.deltaScreenY != 0))
		{
			FlxG.camera.scroll.x -= FlxG.mouse.deltaScreenX / FlxG.camera.zoom;
			FlxG.camera.scroll.y -= FlxG.mouse.deltaScreenY / FlxG.camera.zoom;
			if(FlxG.camera.target != null) FlxG.camera.target = null;
			if(focusRadioGroup.checked > -1) focusRadioGroup.checked = -1;
		}

		// ---- Left-click drag moves the object directly under the cursor ----
		if(!overUI && FlxG.mouse.justPressed)
		{
			draggingSprite = null;
			var i:Int = stageSprites.length;
			while(i-- > 0)
			{
				var spr = stageSprites[i];
				if(spr == null || spr.sprite == null || !spr.visible) continue;
				if(FlxG.mouse.overlaps(spr.sprite, camGame))
				{
					draggingSprite = spr;
					selectSpriteInList(spr);
					checkUIOnObject();
					break;
				}
			}
		}

		if(draggingSprite != null)
		{
			if(FlxG.mouse.pressed)
			{
				var dx:Float = FlxG.mouse.deltaScreenX / FlxG.camera.zoom;
				var dy:Float = FlxG.mouse.deltaScreenY / FlxG.camera.zoom;
				if(dx != 0 || dy != 0)
					moveSelected(dx, dy);
			}
			else
				draggingSprite = null;
		}

		// ---- Arrow-key nudge, kept for precision alongside dragging ----
		var moveX:Float = 0;
		var moveY:Float = 0;
		if (FlxG.keys.justPressed.LEFT || touchPad.buttonLeft.justPressed) moveX -= 5 * shiftMult * ctrlMult;
		if (FlxG.keys.justPressed.RIGHT || touchPad.buttonRight.justPressed) moveX += 5 * shiftMult * ctrlMult;
		if (FlxG.keys.justPressed.UP || touchPad.buttonUp.justPressed) moveY -= 5 * shiftMult * ctrlMult;
		if (FlxG.keys.justPressed.DOWN || touchPad.buttonDown.justPressed) moveY += 5 * shiftMult * ctrlMult;

		if(moveX != 0 || moveY != 0)
			moveSelected(moveX, moveY);
	}

	function moveSelected(moveX:Float, moveY:Float)
	{
		var spr = getSelected(false);
		if(spr == null) return;

		var displayX:Float, displayY:Float;
		spr.x = displayX = Math.round(spr.x + moveX);
		spr.y = displayY = Math.round(spr.y + moveY);
		var char:Character = cast spr.sprite;
		switch(spr.type)
		{
			case 'boyfriend':
				stageJson.boyfriend[0] = displayX = spr.x - char.positionArray[0];
				stageJson.boyfriend[1] = displayY = spr.y - char.positionArray[1];
			case 'gf':
				stageJson.girlfriend[0] = displayX = spr.x - char.positionArray[0];
				stageJson.girlfriend[1] = displayY = spr.y - char.positionArray[1];
			case 'dad':
				stageJson.opponent[0] = displayX = spr.x - char.positionArray[0];
				stageJson.opponent[1] = displayY = spr.y - char.positionArray[1];
		}
		posTxt.visible = true;
		posTxt.text = 'X: $displayX\nY: $displayY';
		unsavedProgress = true;
	}

	var curFilters:LoadFilters = (LOW_QUALITY)|(HIGH_QUALITY);
	override function draw()
	{
		if(persistentDraw || subState == null)
		{
			for (basic in stageSprites)
				if(basic.visible)
					basic.draw(curFilters);

			if(showSelectionQuad && layerRadioGroup.checkedRadio != null)
			{
				var spr = stageSprites[layerRadioGroup.labels.length - layerRadioGroup.checked - 1];
				if(spr != null) drawDebugOnCamera(spr.sprite);
			}
		}
		super.draw();
	}

	public function drawDebugOnCamera(spr:FlxSprite):Void
	{
		if (spr == null || !spr.isOnScreen(FlxG.camera)) return;

		@:privateAccess
		var lineSize:Int = Std.int(Math.max(2, Math.floor(3 / FlxG.camera.zoom)));

		var sprX:Float = spr.x - spr.offset.x;
		var sprY:Float = spr.y - spr.offset.y;
		var sprWidth:Int = Std.int(spr.frameWidth * spr.scale.x);
		var sprHeight:Int = Std.int(spr.frameHeight * spr.scale.y);
		for (num => sel in selectionSprites.members)
		{
			sel.x = sprX;
			sel.y = sprY;
			switch(num)
			{
				case 0: sel.setGraphicSize(sprWidth, lineSize);
				case 1: sel.setGraphicSize(sprWidth, lineSize); sel.y += sprHeight - lineSize;
				case 2: sel.setGraphicSize(lineSize, sprHeight);
				case 3: sel.setGraphicSize(lineSize, sprHeight); sel.x += sprWidth - lineSize;
			}
			sel.updateHitbox();
			sel.scrollFactor.set(spr.scrollFactor.x, spr.scrollFactor.y);
		}
		selectionSprites.draw();
	}

	// ______________________________ Save ______________________________

	function saveObjectsToJson()
	{
		stageJson.objects = [];
		for (basic in stageSprites)
			stageJson.objects.push(basic.formatToJson());
	}

	var _file:FileReference;
	function saveData()
	{
		if(_file != null) return;

		saveObjectsToJson();
		var data = haxe.Json.stringify(stageJson, '\t');
		#if mobile
		unsavedProgress = false;
		StorageUtil.saveContent('$lastLoadedStage.json', data);
		showOutput('Saved!');
		#else
		if (data.length > 0)
		{
			_file = new FileReference();
			_file.addEventListener(#if desktop Event.SELECT #else Event.COMPLETE #end, onSaveComplete);
			_file.addEventListener(Event.CANCEL, onSaveCancel);
			_file.addEventListener(IOErrorEvent.IO_ERROR, onSaveError);
			_file.save(data, '$lastLoadedStage.json');
		}
		#end
	}

	function onSaveComplete(_):Void
	{
		if(_file == null) return;
		_file.removeEventListener(Event.COMPLETE, onSaveComplete);
		_file.removeEventListener(Event.CANCEL, onSaveCancel);
		_file.removeEventListener(IOErrorEvent.IO_ERROR, onSaveError);
		_file = null;
		unsavedProgress = false;
		showOutput('Saved!');
	}

	function onSaveCancel(_):Void
	{
		if(_file == null) return;
		_file.removeEventListener(Event.COMPLETE, onSaveComplete);
		_file.removeEventListener(Event.CANCEL, onSaveCancel);
		_file.removeEventListener(IOErrorEvent.IO_ERROR, onSaveError);
		_file = null;
	}

	function onSaveError(_):Void
	{
		if(_file == null) return;
		_file.removeEventListener(Event.COMPLETE, onSaveComplete);
		_file.removeEventListener(Event.CANCEL, onSaveCancel);
		_file.removeEventListener(IOErrorEvent.IO_ERROR, onSaveError);
		_file = null;
		showOutput('Problem saving file', true);
	}

	override function destroy()
	{
		destroySubStates = true;
		super.destroy();
	}
}

class BetterStageEditorExitPrompt extends MusicBeatSubstate
{
	public function new()
	{
		super();

		var bg:FlxSprite = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		bg.alpha = 0.7;
		bg.scale.set(FlxG.width, FlxG.height);
		bg.updateHitbox();
		bg.scrollFactor.set();
		add(bg);

		var boxBg:FlxSprite = new FlxSprite().makeGraphic(1, 1, FlxColor.BLACK);
		boxBg.alpha = 0.9;
		boxBg.scale.set(420, 160);
		boxBg.updateHitbox();
		boxBg.screenCenter();
		boxBg.scrollFactor.set();
		add(boxBg);

		var txt:FlxText = new FlxText(0, boxBg.y + 20, 400, 'You have unsaved changes.\nAre you sure you want to exit?', 20);
		txt.alignment = CENTER;
		txt.screenCenter(X);
		txt.scrollFactor.set();
		add(txt);

		var exitState = cast(FlxG.state, BetterStageEditorState);

		var discardBtn:PsychUIButton = new PsychUIButton(0, boxBg.y + boxBg.height - 45, 'Discard & Exit', function()
		{
			close();
			MusicBeatState.switchState(new states.editors.MasterEditorMenu());
			FlxG.sound.playMusic(Paths.music('freakyMenu'));
		});
		discardBtn.normalStyle.bgColor = FlxColor.RED;
		discardBtn.normalStyle.textColor = FlxColor.WHITE;
		discardBtn.screenCenter(X);
		discardBtn.x -= 110;
		add(discardBtn);

		var cancelBtn:PsychUIButton = new PsychUIButton(0, boxBg.y + boxBg.height - 45, 'Cancel', function() close());
		cancelBtn.screenCenter(X);
		cancelBtn.x += 110;
		add(cancelBtn);
	}
}

