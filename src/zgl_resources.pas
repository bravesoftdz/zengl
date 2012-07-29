{
 *  Copyright © Andrey Kemka aka Andru
 *  mail: dr.andru@gmail.com
 *  site: http://zengl.org
 *
 *  This file is part of ZenGL.
 *
 *  ZenGL is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Lesser General Public License as
 *  published by the Free Software Foundation, either version 3 of
 *  the License, or (at your option) any later version.
 *
 *  ZenGL is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with ZenGL. If not, see http://www.gnu.org/licenses/
}
unit zgl_resources;

{$I zgl_config.cfg}

interface
uses
  {$IFDEF WINDOWS}
  Windows,
  {$ENDIF}
  zgl_memory,
  zgl_textures,
  zgl_font,
  {$IFDEF USE_SOUND}
  zgl_sound,
  {$ENDIF}
  {$IFDEF USE_ZIP}
  zgl_lib_zip,
  {$ENDIF}
  zgl_threads,
  zgl_utils,
  zgl_types;

const
  RES_TEXTURE           = $000001;
  RES_TEXTURE_FRAMESIZE = $000002;
  RES_TEXTURE_MASK      = $000003;
  RES_TEXTURE_DELETE    = $000004;
  RES_FONT              = $000010;
  RES_FONT_DELETE       = $000011;
  RES_SOUND             = $000020;
  RES_SOUND_DELETE      = $000021;
  RES_ZIP_OPEN          = $000030;
  RES_ZIP_CLOSE         = $000031;

type
  zglPResourceItem = ^zglTResourceItem;
  zglTResourceItem = record
    Type_      : Integer;
    IsFromFile : Boolean;
    Ready      : Boolean;
    Prepared   : Boolean;
    Resource   : Pointer;

    prev, next : zglPResourceItem;
  end;

type
  zglPTextureResource = ^zglTTextureResource;
  zglTTextureResource = record
    FileName         : UTF8String;
    Memory           : zglTMemory;
    Texture          : zglPTexture;
    FileLoader       : zglTTextureFileLoader;
    MemLoader        : zglTTextureMemLoader;
    pData            : PByteArray;
    TransparentColor : LongWord;
    Flags            : LongWord;
    Format           : Word;
    Width, Height    : Word;
  end;

type
  zglPTextureFrameSizeResource = ^zglTTextureFrameSizeResource;
  zglTTextureFrameSizeResource = record
    Texture     : zglPTexture;
    FrameWidth  : Integer;
    FrameHeight : Integer;
  end;

type
  zglPTextureMaskResource = ^zglTTextureMaskResource;
  zglTTextureMaskResource = record
    Texture : zglPTexture;
    Mask    : zglPTexture;
    tData   : PByteArray;
    mData   : PByteArray;
  end;

type
  zglPFontResource = ^zglTFontResource;
  zglTFontResource = record
    FileName : UTF8String;
    Memory   : zglTMemory;
    Font     : zglPFont;
    pData    : array of PByteArray;
    Format   : array of Word;
    Width    : array of Word;
    Height   : array of Word;
  end;

{$IFDEF USE_SOUND}
type
  zglPSoundResource = ^zglTSoundResource;
  zglTSoundResource = record
    FileName   : UTF8String;
    Memory     : zglTMemory;
    Sound      : zglPSound;
    FileLoader : zglTSoundFileLoader;
    MemLoader  : zglTSoundMemLoader;
    Format     : LongWord;
  end;
{$ENDIF}

{$IFDEF USE_ZIP}
type
  zglPZIPResource = ^zglTZIPResource;
  zglTZIPResource = record
    FileName : UTF8String;
    Password : UTF8String;
  end;
{$ENDIF}

procedure res_Init;
procedure res_Free;
procedure res_Proc;
procedure res_AddToQueue( Type_ : Integer; FromFile : Boolean; Resource : Pointer );

procedure res_BeginQueue( QueueID : Byte );
procedure res_EndQueue;
function  res_GetPercentage( QueueID : Byte ) : Integer;
function  res_GetCompleted : Integer;

var
  resUseThreaded : Boolean;
  resCompleted   : Integer;

implementation
uses
  zgl_main,
  zgl_application,
  zgl_file,
  zgl_log;

var
  resThread          : array[ 0..255 ] of zglTThread;
  resQueueStackID    : array of Byte;
  resQueueID         : array[ 0..255 ] of Byte;
  resQueueCurrentID  : Byte;
  resQueueState      : array[ 0..255 ] of zglTEvent;
  resQueueSize       : array[ 0..255 ] of Integer;
  resQueueMax        : array[ 0..255 ] of Integer;
  resQueuePercentage : array[ 0..255 ] of Integer;
  resQueueItems      : array[ 0..255 ] of zglTResourceItem;

procedure res_Init;
begin
end;

procedure res_DelItem( var Item : zglPResourceItem );
begin
  if not Assigned( Item ) Then exit;

  if Assigned( Item.prev ) Then
    Item.prev.next := Item.next;
  if Assigned( Item.next ) Then
    Item.next.prev := Item.prev;

  case Item.Type_ of
    RES_TEXTURE:
      if Assigned( Item.Resource ) Then
        zglPTextureResource( Item.Resource ).FileName := '';
    RES_FONT:
      if Assigned( Item.Resource ) Then
        zglPFontResource( Item.Resource ).FileName := '';
    {$IFDEF USE_SOUND}
    RES_SOUND:
      if Assigned( Item.Resource ) Then
        zglPSoundResource( Item.Resource ).FileName := '';
    {$ENDIF}
    {$IFDEF USE_ZIP}
    RES_ZIP_OPEN,
    RES_ZIP_CLOSE:
      if Assigned( Item.Resource ) Then
        with zglPZIPResource( Item.Resource )^ do
          begin
            FileName := '';
            Password := '';
          end;
    {$ENDIF}
  end;

  FreeMem( Item.Resource );
  FreeMem( Item );
  Item := nil;
end;

procedure res_Free;
  var
    i : Integer;
    r : zglPResourceItem;
begin
  for i := 0 to 255 do
    if resQueueState[ i ] <> nil Then
      begin
        thread_EventSet( resQueueState[ i ] );
        resQueueSize[ i ] := 0;
        while resQueueState[ i ] <> nil do;
        thread_Close( resThread[ i ] );

        while Assigned( resQueueItems[ i ].next ) do
          begin
            r := resQueueItems[ i ].next;
            res_DelItem( r );
          end;
        resQueueItems[ i ].prev := nil;
        resQueueItems[ i ].next := nil;
      end;
end;

procedure res_Proc;
  var
    item : zglPResourceItem;
    id   : Integer;
    size : Integer;
    max  : Integer;
    i    : Integer;
begin
  size := 0;
  max  := 0;
  for id := 0 to 255 do
    if appWork and ( resQueueState[ id ] <> nil ) Then
      begin
        if resQueueSize[ id ] <= 0 Then continue;

        item := resQueueItems[ id ].next;
        while Assigned( item ) do
          begin
            if ( item.Ready ) and Assigned( item.Resource ) Then
              case item.Type_ of
                RES_TEXTURE:
                  with zglPTextureResource( item.Resource )^ do
                    begin
                      tex_CreateGL( Texture^, pData );
                      FreeMem( pData );
                      if item.IsFromFile Then
                        log_Add( 'Texture loaded: "' + FileName + '"' );

                      FileName := '';
                      FreeMem( item.Resource );
                      item.Resource := nil;
                      DEC( resQueueSize[ id ] );
                      break;
                    end;
                RES_TEXTURE_MASK:
                  with zglPTextureMaskResource( item.Resource )^ do
                    begin
                      tex_SetData( Texture, tData, 0, 0, Round( Texture.Width / Texture.U ), Texture.Height );
                      FreeMem( tData );
                      FreeMem( mData );

                      FreeMem( item.Resource );
                      item.Resource := nil;
                      DEC( resQueueSize[ id ] );
                      break;
                    end;
                RES_FONT:
                  with zglPFontResource( item.Resource )^ do
                    if item.Prepared Then
                      begin
                        for i := 0 to Font.Count.Pages - 1 do
                          begin
                            tex_CreateGL( Font.Pages[ i ]^, pData[ i ] );
                            FreeMem( pData[ i ] );
                          end;
                        SetLength( pData, 0 );
                        SetLength( Format, 0 );
                        SetLength( Width, 0 );
                        SetLength( Height, 0 );

                        FileName := '';
                        FreeMem( item.Resource );
                        item.Resource := nil;
                        DEC( resQueueSize[ id ] );
                        break;
                      end;
              end;
            if ( not item.Prepared ) and Assigned( item.Resource ) Then
              case item.Type_ of
                RES_TEXTURE_MASK:
                  with zglPTextureMaskResource( item.Resource )^ do
                    begin
                      tex_GetData( Texture, tData );
                      tex_GetData( Mask, mData );
                      item.Prepared := TRUE;
                      thread_EventSet( resQueueState[ id ] );
                      break;
                    end;
                RES_FONT:
                  if item.Ready Then
                    with zglPFontResource( item.Resource )^ do
                      begin
                        for i := 0 to Font.Count.Pages - 1 do
                          Font.Pages[ i ] := tex_Add();
                        item.Prepared := TRUE;
                        thread_EventSet( resQueueState[ id ] );
                        item.Ready := FALSE;
                      end;
              end;

            if ( resQueueSize[ id ] = 0 ) or ( not item.Ready ) Then
              break
            else
              item := item.next;
          end;

        INC( size, resQueueSize[ id ] );
        INC( max, resQueueMax[ id ] );
        if resQueueSize[ id ] = 0 Then
          begin
            resQueuePercentage[ id ] := 100;
            resQueueMax[ id ]        := 0;
          end else
            resQueuePercentage[ id ] := Round( ( 1 - resQueueSize[ id ] / resQueueMax[ id ] ) * 100 );
      end;

  if size = 0 Then
    resCompleted := 100
  else
    resCompleted := Round( ( 1 - size / max ) * 100 );
end;

procedure res_AddToQueue( Type_ : Integer; FromFile : Boolean; Resource : Pointer );
  var
    item : ^zglPResourceItem;
    last : zglPResourceItem;
    tex  : zglPTextureResource;
    tfs  : zglPTextureFrameSizeResource;
    tm   : zglPTextureMaskResource;
    fnt  : zglPFontResource;
    {$IFDEF USE_SOUND}
    snd  : zglPSoundResource;
    {$ENDIF}
    {$IFDEF USE_ZIP}
    zip : zglPZIPResource;
    {$ENDIF}
begin
  item := @resQueueItems[ resQueueCurrentID ].next;
  last := @resQueueItems[ resQueueCurrentID ];
  while Assigned( item^ ) do
    begin
      last := item^;
      item := @item^.next;
    end;

  INC( resQueueSize[ resQueueCurrentID ] );
  INC( resQueueMax[ resQueueCurrentID ] );
  resQueuePercentage[ resQueueCurrentID ] := Round( ( 1 - resQueueSize[ resQueueCurrentID ] / resQueueMax[ resQueueCurrentID ] ) * 100 );
  if resCompleted = 100 Then
    resCompleted := 0;

  zgl_GetMem( Pointer( item^ ), SizeOf( zglTResourceItem ) );

  case Type_ of
    RES_TEXTURE:
      begin
        zgl_GetMem( Pointer( tex ), SizeOf( zglTTextureResource ) );
        with zglPTextureResource( Resource )^ do
          begin
            tex.FileName         := FileName;
            tex.Memory           := Memory;
            tex.Texture          := Texture;
            tex.FileLoader       := FileLoader;
            tex.MemLoader        := MemLoader;
            tex.TransparentColor := TransparentColor;
            tex.Flags            := Flags;
          end;
        item^.Resource := tex;
      end;
    RES_TEXTURE_FRAMESIZE:
      begin
        zgl_GetMem( Pointer( tfs ), SizeOf( zglTTextureFrameSizeResource ) );
        with zglPTextureFrameSizeResource( Resource )^ do
          begin
            tfs.Texture     := Texture;
            tfs.FrameWidth  := FrameWidth;
            tfs.FrameHeight := FrameHeight;
          end;
        item^.Resource := tfs;
      end;
    RES_TEXTURE_MASK:
      begin
        zgl_GetMem( Pointer( tm ), SizeOf( zglTTextureMaskResource ) );
        with zglPTextureMaskResource( Resource )^ do
          begin
            tm.Texture := Texture;
            tm.Mask    := Mask;
          end;
        item^.Resource := tm;
      end;
    RES_TEXTURE_DELETE:
      begin
      end;
    RES_FONT:
      begin
        zgl_GetMem( Pointer( fnt ), SizeOf( zglTFontResource ) );
        with zglPFontResource( Resource )^ do
          begin
            fnt.FileName := FileName;
            fnt.Memory   := Memory;
            fnt.Font     := Font;
          end;
        item^.Resource := fnt;
      end;
    RES_FONT_DELETE:
      begin
      end;
    {$IFDEF USE_SOUND}
    RES_SOUND:
      begin
        zgl_GetMem( Pointer( snd ), SizeOf( zglTSoundResource ) );
        with zglPSoundResource( Resource )^ do
          begin
            snd.FileName   := FileName;
            snd.Memory     := Memory;
            snd.Sound      := Sound;
            snd.FileLoader := FileLoader;
            snd.MemLoader  := MemLoader;
          end;
        item^.Resource := snd;
      end;
    RES_SOUND_DELETE:
      begin
      end;
    {$ENDIF}
    {$IFDEF USE_ZIP}
    RES_ZIP_OPEN,
    RES_ZIP_CLOSE:
      begin
        zgl_GetMem( Pointer( zip ), SizeOf( zglTZIPResource ) );
        with zglPZIPResource( Resource )^ do
          begin
            zip.FileName := FileName;
            zip.Password := Password;
          end;
        item^.Resource := zip;
      end;
    {$ENDIF}
  end;

  item^.prev       := last;
  item^.next       := nil;
  item^.prev.next  := item^;
  item^.Prepared   := FALSE;
  item^.Ready      := FALSE;
  item^.IsFromFile := FromFile;
  item^.Type_      := Type_;

  thread_EventSet( resQueueState[ resQueueCurrentID ] );
end;

function res_ProcQueue( data : Pointer ) : LongInt; {$IFDEF USE_EXPORT_C} register; {$ENDIF}
  var
    id   : Byte;
    item : zglPResourceItem;
    idel : zglPResourceItem;
    // mask
    i, j, rW : Integer;
    // font
    mem  : zglTMemory;
    dir  : UTF8String;
    name : UTF8String;
    tmp  : UTF8String;
begin
  {$IFDEF iOS}
  app_InitPool();
  {$ENDIF}

  Result := 0;
  id     := PByte( data )^;
  while appWork do
    begin
      item := resQueueItems[ id ].next;
      idel := nil;
      while appWork and Assigned( item ) do
        begin
          if ( not item.Ready ) and Assigned( item.Resource ) Then
            case item.Type_ of
              RES_TEXTURE:
                with item^, zglPTextureResource( Resource )^ do
                  begin
                    if IsFromFile Then
                      begin
                        if not file_Exists( FileName ) Then
                          begin
                            log_Add( 'Cannot read "' + FileName + '"' );

                            FileName := '';
                            FreeMem( Resource );
                            Resource := nil;
                            DEC( resQueueSize[ id ] );
                          end else
                            FileLoader( FileName, pData, Width, Height, Format )
                      end else
                        begin
                          FileName := 'From Memory';
                          MemLoader( Memory, pData, Width, Height, Format );
                        end;

                    if not Assigned( pData ) Then
                      begin
                        log_Add( 'Unable to load texture: "' + FileName + '"' );

                        FileName := '';
                        FreeMem( Resource );
                        Resource := nil;
                        DEC( resQueueSize[ id ] );
                      end else
                        begin
                          Texture.Width  := Width;
                          Texture.Height := Height;
                          Texture.Flags  := Flags;
                          Texture.Format := Format;
                          if Texture.Format = TEX_FORMAT_RGBA Then
                            begin
                              if Texture.Flags and TEX_CALCULATE_ALPHA > 0 Then
                                begin
                                  tex_CalcTransparent( pData, TransparentColor, Width, Height );
                                  tex_CalcAlpha( pData, Width, Height );
                                end else
                                  tex_CalcTransparent( pData, TransparentColor, Width, Height );
                            end;
                          tex_CalcFlags( Texture^, pData );
                          tex_CalcTexCoords( Texture^ );
                          Ready := TRUE;
                        end;
                  end;
              RES_TEXTURE_FRAMESIZE:
                with item^, zglPTextureFrameSizeResource( Resource )^ do
                  begin
                    if Assigned( Texture ) Then
                      tex_CalcTexCoords( Texture^, Round( Texture.Width ) div FrameWidth, Round( Texture.Height ) div FrameHeight );

                    FreeMem( Resource );
                    Resource := nil;
                    Ready := TRUE;
                    DEC( resQueueSize[ id ] );
                  end;
              RES_TEXTURE_MASK:
                if item.Prepared Then
                  with item^, zglPTextureMaskResource( Resource )^ do
                    begin
                      if ( Texture.Width <> Mask.Width ) or ( Texture.Height <> Mask.Height ) or ( Texture.Format <> TEX_FORMAT_RGBA ) or ( Mask.Format <> TEX_FORMAT_RGBA ) Then
                        begin
                          FreeMem( Resource );
                          Resource := nil;
                          DEC( resQueueSize[ id ] );
                        end;

                      rW := Round( Texture.Width / Texture.U );

                      for j := 0 to Texture.Height - 1 do
                        begin
                          for i := 0 to rW - 1 do
                            tData[ i * 4 + 3 ] := mData[ i * 4 ];
                          INC( PByte( tData ), rW * 4 );
                          INC( PByte( mData ), rW * 4 );
                        end;
                      DEC( PByte( tData ), rW * Texture.Height * 4 );
                      DEC( PByte( mData ), rW * Mask.Height * 4 );

                      Ready := TRUE;
                    end;
              RES_FONT:
                with item^, zglPFontResource( Resource )^ do
                  begin
                    if not Prepared Then
                      begin
                        if IsFromFile Then
                          mem_LoadFromFile( mem, FileName )
                        else
                          begin
                            FileName := 'From Memory';
                            mem := Memory;
                          end;

                        font_Load( Font, mem );

                        if IsFromFile Then
                          mem_Free( mem );

                        if Assigned( Font ) Then
                          begin
                            if IsFromFile Then
                              begin
                                dir  := file_GetDirectory( FileName );
                                name := file_GetName( FileName );
                                SetLength( pData, Font.Count.Pages );
                                SetLength( Format, Font.Count.Pages );
                                SetLength( Width, Font.Count.Pages );
                                SetLength( Height, Font.Count.Pages );
                                for i := 0 to Font.Count.Pages - 1 do
                                  for j := managerTexture.Count.Formats - 1 downto 0 do
                                    begin
                                      tmp := dir + name + '-page' + u_IntToStr( i ) + '.' + u_StrDown( managerTexture.Formats[ j ].Extension );
                                      if file_Exists( tmp ) Then
                                        begin
                                          managerTexture.Formats[ j ].FileLoader( tmp, pData[ i ], Width[ i ], Height[ i ], Format[ i ] );
                                          log_Add( 'Texture loaded: "' + tmp + '"'  );
                                          break;
                                        end;
                                    end;
                              end;

                            Ready := TRUE;
                          end else
                            begin
                              log_Add( 'Unable to load font: "' + FileName + '"' );

                              FileName := '';
                              FreeMem( Resource );
                              Resource := nil;
                              DEC( resQueueSize[ id ] );
                            end;
                      end else
                        begin
                          for i := 0 to Font.Count.Pages - 1 do
                            begin
                              Font.Pages[ i ].Flags  := TEX_DEFAULT_2D;
                              Font.Pages[ i ].Format := Format[ i ];
                              Font.Pages[ i ].Width  := Width[ i ];
                              Font.Pages[ i ].Height := Height[ i ];
                              if Format[ i ] = TEX_FORMAT_RGBA Then
                                tex_CalcAlpha( pData[ i ], Width[ i ], Height[ i ] );
                              tex_CalcFlags( Font.Pages[ i ]^, pData[ i ] );
                              tex_CalcTexCoords( Font.Pages[ i ]^ );
                            end;

                          Ready := TRUE;
                        end;
                  end;
              {$IFDEF USE_SOUND}
              RES_SOUND:
                with item^, zglPSoundResource( Resource )^ do
                  begin
                    if IsFromFile Then
                      begin
                        if not file_Exists( FileName ) Then
                          begin
                            log_Add( 'Cannot read "' + FileName + '"' );

                            FileName := '';
                            FreeMem( Resource );
                            Resource := nil;
                            DEC( resQueueSize[ id ] );
                          end else
                            FileLoader( FileName, Sound.Data, Sound.Size, Format, Sound.Frequency )
                      end else
                        begin
                          FileName := 'From Memory';
                          MemLoader( Memory, Sound.Data, Sound.Size, Format, Sound.Frequency );
                        end;

                    if Assigned( Sound.Data ) Then
                      begin
                        snd_Create( Sound^, Format );
                        if IsFromFile Then
                          log_Add( 'Sound loaded: "' + FileName + '"' );
                      end else
                        log_Add( 'Unable to load sound: "' + FileName + '"' );

                    FileName := '';
                    FreeMem( Resource );
                    Resource := nil;
                    Ready := TRUE;
                    DEC( resQueueSize[ id ] );
                  end;
              {$ENDIF}
              {$IFDEF USE_ZIP}
              RES_ZIP_OPEN:
                with item^, zglPZIPResource( Resource )^ do
                  begin
                    {$IF DEFINED(MACOSX) or DEFINED(iOS) or DEFINED(WINCE)}
                    zipCurrent := zip_open( PAnsiChar( platform_GetRes( FileName ) ), 0, i );
                    {$ELSE}
                    zipCurrent := zip_open( PAnsiChar( FileName ), 0, i );
                    {$IFEND}

                    if zipCurrent = nil Then
                      begin
                        log_Add( 'Unable to open archive: ' + FileName );
                      end else
                        begin
                          if Password = '' Then
                            zip_set_default_password( zipCurrent, nil )
                          else
                            zip_set_default_password( zipCurrent, PAnsiChar( Password ) );
                        end;

                    FileName := '';
                    Password := '';
                    FreeMem( Resource );
                    Resource := nil;
                    Ready := TRUE;
                    DEC( resQueueSize[ id ] );
                  end;
              RES_ZIP_CLOSE:
                with item^, zglPZIPResource( Resource )^ do
                  begin
                    zip_close( zipCurrent );
                    zipCurrent := nil;

                    FileName := '';
                    Password := '';
                    FreeMem( Resource );
                    Resource := nil;
                    Ready := TRUE;
                    DEC( resQueueSize[ id ] );
                  end;
              {$ENDIF}
            end else
              if ( item.Ready ) and ( not Assigned( item.Resource ) ) Then
                begin
                  idel := item;
                  if Assigned( item.prev ) Then
                    item.prev.next := item.next;
                  if Assigned( item.next ) Then
                    item.next.prev := item.prev;
                end;

          item := item.next;
          if Assigned( idel ) Then
            begin
              FreeMem( idel );
              idel := nil;
            end;
        end;

      thread_EventWait( resQueueState[ id ] );
      thread_EventReset( resQueueState[ id ] );
    end;

  {$IFDEF iOS}
  app_FreePool();
  {$ENDIF}

  thread_EventDestroy( resQueueState[ id ] );
  EndThread( 0 );
end;

procedure res_BeginQueue( QueueID : Byte );
begin
  if resQueueState[ QueueID ] = nil Then
    begin
      resQueueID[ QueueID ]         := QueueID;
      resQueueItems[ QueueID ].prev := @resQueueItems[ QueueID ];
      resQueueItems[ QueueID ].next := nil;
      thread_EventCreate( resQueueState[ QueueID ] );
      thread_Create( resThread[ QueueID ], @res_ProcQueue, @resQueueID[ QueueID ] );
    end;

  SetLength( resQueueStackID, Length( resQueueStackID ) + 1 );
  resQueueStackID[ Length( resQueueStackID ) - 1 ] := QueueID;

  resQueueCurrentID := QueueID;
  resUseThreaded := TRUE;
end;

procedure res_EndQueue;
begin
  if Length( resQueueStackID ) > 0 Then
    begin
      resQueueCurrentID := resQueueStackID[ Length( resQueueStackID ) - 1 ];
      SetLength( resQueueStackID, Length( resQueueStackID ) - 1 );
      if Length( resQueueStackID ) > 0 Then
        exit;
    end;

  resUseThreaded := FALSE;
end;

function res_GetPercentage( QueueID : Byte ) : Integer;
begin
  Result := resQueuePercentage[ QueueID ];
end;

function res_GetCompleted : Integer;
begin
  Result := resCompleted;
end;

end.
