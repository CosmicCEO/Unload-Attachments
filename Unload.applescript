    (*
        Change Content of a Message and Save — macOS Mail Edition
        Version 1.0

        Rewritten from the original Outlook 2016 script by Jerod Price.

        When one or more emails are selected in Mail.app and this script is run:
          • Each email is checked for attachments
          • Office and PDF files (xls, xlsx, doc, docx, ppt, pptx, pdf) are saved
            to ~/Downloads/MailAttachments-YYYY/
          • Those attachments are removed from the email
          • An HTML summary table is prepended to the email body
          • System notifications appear for each save and a final summary

        To change the save location, update the downloadFolder property below.
    *)

    -- ============================================================
    -- Configuration
    -- ============================================================

    property disallowedChars  : ":;,'/|!@#$%^&*()-"
    property disallowedChars2 : " "
    property replacementChar  : ""

    -- File types to save and remove from the email
    property isOffice : {"xls", "xlsx", "doc", "docx", "ppt", "pptx", "pdf"}

    -- File types to leave alone (not deleted)
    property isGraphic : {"jpg", "jpeg", "png", "tiff", "gif", "heic", "webp"}

    -- HTML helpers
    property br  : "<br>"
    property td1 : "<td style='padding:4px 8px; border:1px solid #ccc;'>"
    property td2 : "</td>"

    -- ============================================================
    -- Setup
    -- ============================================================

    set ScriptTitle to "Mail Attachment Removal"
    set currentYear to (year of (current date)) as string

    -- Build the save path — change "Downloads/MailAttachments" to your preference
    set myHome to POSIX path of (path to home folder as string)
    set downloadFolder to myHome & "Downloads/MailAttachments-" & currentYear & "/"

    -- Create the folder if it doesn't exist
    do shell script "mkdir -p " & quoted form of downloadFolder

    -- ============================================================
    -- Main
    -- ============================================================

    tell application "Mail"
        set selectedMessages to selection

        -- Nothing selected — warn and quit
        if selectedMessages is {} then
            display notification "Please select a message first." with title ScriptTitle subtitle "Input not Available"
            return
        end if

        repeat with theMessage in selectedMessages
            -- Grab message metadata
            set theName to subject of theMessage
            set theTime to date received of theMessage
            set theShortTime to time string of theTime as string
            set theCleanTime to my CleanName(theShortTime)
            set theContent to content of theMessage

            -- attachmentList: each item is a list of:
            --   {nameofAttachment, savedPath, sizeString, wasExamined, shouldDelete, wasSaved, wasDeleted}
            set attachmentList to {}

            -- Iterate in REVERSE so deleting one attachment doesn't shift the index of the next
            set attachCount to count of mail attachments of theMessage

            repeat with i from attachCount to 1 by -1
                set thisAttachment to item i of (mail attachments of theMessage)
                set nameofAttachment to name of thisAttachment
                set extensionDigits to my getExtension(nameofAttachment)
                set sizeString to my convertByteSize((file size of thisAttachment) as integer, missing value, 2)
                set clearedName to my CleanName(nameofAttachment)
                set savedPath to downloadFolder & theCleanTime & "_" & clearedName

                -- Track every attachment we see
                set anAttachment to {nameofAttachment, savedPath, sizeString, true, false, false, false}

                if isOffice contains extensionDigits then
                    -- Mark it as something we should save and delete
                    set item 5 of anAttachment to true

                    try
                        -- Save the attachment; Mail places it with its original filename
                        set destFolderAlias to (POSIX file downloadFolder) as alias
                        save thisAttachment in destFolderAlias

                        -- Rename to timestamped clean name to avoid collisions
                        set originalSavedPath to downloadFolder & nameofAttachment
                        if originalSavedPath is not savedPath then
                            do shell script "mv " & quoted form of originalSavedPath & " " & quoted form of savedPath
                        end if

                        -- Mark as saved
                        set item 6 of anAttachment to true
                        display notification "Saved: " & nameofAttachment with title ScriptTitle subtitle "Success"

                        -- Remove the attachment from the email
                        delete thisAttachment

                        -- Mark as deleted
                        set item 7 of anAttachment to true

                    on error errMsg number errNum
                        display notification "Error saving " & nameofAttachment & " (" & errNum & ")" with title ScriptTitle subtitle "Error"
                    end try

                else if isGraphic contains extensionDigits then
                    -- Left alone intentionally
                    set item 5 of anAttachment to false
                end if

                -- Prepend so the list stays in the original top-down order
                set attachmentList to {anAttachment} & attachmentList
            end repeat

            -- Build an HTML summary table and prepend it to the message body
            if (count of attachmentList) > 0 then
                set HTMLRows to ""
                repeat with a in attachmentList
                    set attName    to item 1 of a
                    set attPath    to item 2 of a
                    set attSize    to item 3 of a
                    set attDeleted to item 7 of a

                    if attDeleted then
                        set linkHTML to "<a href='file://" & my pathToURL(attPath) & "'>open file</a>"
                        set statusHTML to "✓ Saved & removed"
                    else if (item 5 of a) then
                        set linkHTML to ""
                        set statusHTML to "⚠ Error — not removed"
                    else
                        set linkHTML to ""
                        set statusHTML to "— left in place"
                    end if

                    set HTMLRows to HTMLRows & "<tr>" & ¬
                        td1 & attName & td2 & ¬
                        td1 & attSize & td2 & ¬
                        td1 & statusHTML & td2 & ¬
                        td1 & linkHTML & td2 & ¬
                        "</tr>"
                end repeat

                set tableStyle to "border-collapse:collapse; font-family:sans-serif; font-size:12px; margin-bottom:12px;"
                set headerStyle to "background:#f0f0f0; padding:4px 8px; border:1px solid #ccc; text-align:left;"
                set HTMLTable to "<table style='" & tableStyle & "'>" & ¬
                    "<tr>" & ¬
                    "<th style='" & headerStyle & "'>Attachment</th>" & ¬
                    "<th style='" & headerStyle & "'>Size</th>" & ¬
                    "<th style='" & headerStyle & "'>Status</th>" & ¬
                    "<th style='" & headerStyle & "'>Link</th>" & ¬
                    "</tr>" & HTMLRows & "</table>"

                set content of theMessage to HTMLTable & br & theContent
            end if

        end repeat

    end tell

    display notification "Done — check ~/Downloads/MailAttachments-" & currentYear with title ScriptTitle subtitle "All messages processed"


    -- ============================================================
    -- Helper Handlers
    -- ============================================================

    -- Returns the lowercase file extension without the leading dot
    on getExtension(fileName)
        set ext to ""
        try
            set dotPos to 0
            repeat with i from (count of fileName) to 1 by -1
                if character i of fileName is "." then
                    set dotPos to i
                    exit repeat
                end if
            end repeat
            if dotPos > 0 then
                set ext to text (dotPos + 1) through -1 of fileName
            end if
            -- Lowercase via shell (handles edge cases)
            set ext to do shell script "printf '%s' " & quoted form of ext & " | tr '[:upper:]' '[:lower:]'"
        end try
        return ext
    end getExtension

    -- Replaces disallowed characters; removes spaces
    on CleanName(theName)
        set newName to ""
        repeat with i from 1 to length of theName
            set c to character i of theName
            if c is in disallowedChars then
                set newName to newName & replacementChar
            else if c is in disallowedChars2 then
                set newName to newName & ""
            else
                set newName to newName & c
            end if
        end repeat
        return newName
    end CleanName

    -- URL-encodes a POSIX path for use in an href (Python 3 compatible)
    on pathToURL(thePath)
        try
            return do shell script "python3 -c \"import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))\" " & quoted form of thePath
        on error
            return thePath
        end try
    end pathToURL

    -- Converts a byte count to a human-readable string (KB / MB / GB)
    on convertByteSize(byteSize, KBSize, decPlaces)
        if KBSize is missing value then set KBSize to 1024
        if byteSize = 1 then return "1 byte"
        if byteSize < KBSize then return (byteSize as string) & " bytes"

        set suffixes to {" KB", " MB", " GB", " TB"}
        set dpShift to 10 ^ decPlaces
        repeat with p from 1 to count of suffixes
            if byteSize < (KBSize ^ (p + 1)) or p = (count of suffixes) then
                set val to (((byteSize / (KBSize ^ p)) * dpShift) div 1) / dpShift
                return (val as string) & item p of suffixes
            end if
        end repeat
        return (byteSize as string) & " bytes"
    end convertByteSize
